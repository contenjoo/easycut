//! Prompt video creation. Credentials remain in the OS credential store and travel
//! to our fixed worker over stdin; generated sources never receive them.
use crate::{ai, emit_state, media, tools, AppState};
use easycut_core::{Id, MediaKind};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

const OPENAI_SERVICE: &str = "com.contenjoo.easycut.openai";
const MAX_OUTPUT: usize = 2 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub struct Request {
    pub renderer: String,
    pub provider: String,
    pub access: String,
    pub model: String,
    pub prompt: String,
    pub duration: f64,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub automatic_skills: bool,
}
impl Default for Request {
    fn default() -> Self {
        Self { renderer: "canvas".into(), provider: "claude".into(), access: "subscription".into(),
            model: "claude-opus-5-5".into(), prompt: String::new(), duration: 20.0,
            width: 1080, height: 1080, fps: 30, automatic_skills: true }
    }
}
impl Request {
    pub fn validate(&self) -> Result<(), String> {
        if !["canvas", "remotion"].contains(&self.renderer.as_str()) ||
            !["claude", "openai", "gemini"].contains(&self.provider.as_str()) ||
            !["subscription", "api"].contains(&self.access.as_str()) {
            return Err("영상 제작 AI와 연결 방식을 확인하세요.".into());
        }
        if self.provider == "gemini" && self.access != "api" { return Err("Gemini는 API 키로 연결해 주세요.".into()); }
        if self.prompt.trim().is_empty() || self.prompt.chars().count() > 20_000 || !self.duration.is_finite() ||
            !(2.0..=60.0).contains(&self.duration) || ![24, 30, 60].contains(&self.fps) ||
            !(320..=1920).contains(&self.width) || !(320..=1920).contains(&self.height) ||
            self.width % 2 != 0 || self.height % 2 != 0 {
            return Err("영상 설명과 설정을 확인하세요. 길이는 2~60초, 크기는 320~1920, fps는 24·30·60을 지원합니다.".into());
        }
        if self.model.is_empty() || self.model.len() > 120 ||
            !self.model.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)) {
            return Err("사용할 AI 모델 이름을 확인하세요.".into());
        }
        Ok(())
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    busy: bool,
    status: String,
    error: Option<String>,
    job_id: Option<String>,
    previews: Vec<String>,
    applied_skills: Vec<Value>,
    applied_skill_reason: String,
    output_path: Option<String>,
    request: Option<Request>,
}
impl Default for Snapshot {
    fn default() -> Self {
        Self { busy: false, status: String::new(), error: None, job_id: None, previews: vec![],
            applied_skills: vec![], applied_skill_reason: String::new(), output_path: None, request: None }
    }
}
#[derive(Default)]
struct Inner {
    token: u64,
    state: Snapshot,
    directory: Option<PathBuf>,
    control: Option<Arc<ProcessTree>>,
}
#[derive(Default)]
pub struct Generation(Mutex<Inner>);

fn snapshot(app: &AppHandle) -> Value {
    serde_json::to_value(&app.state::<Generation>().0.lock().unwrap().state).unwrap_or(Value::Null)
}
fn notify(app: &AppHandle) {
    let _ = app.emit("video-generation", snapshot(app));
}
pub fn cancel(app: &AppHandle) {
    let control = {
        let state = app.state::<Generation>();
        let mut inner = state.0.lock().unwrap();
        inner.token = inner.token.wrapping_add(1);
        if inner.state.busy { inner.state.status = "중지됨".into(); }
        inner.state.busy = false;
        inner.control.take()
    };
    if let Some(control) = control { control.terminate(); }
    notify(app);
}

fn service(provider: &str) -> Result<&'static str, String> {
    match provider {
        "claude" => Ok("com.contenjoo.easycut.anthropic"),
        "openai" => Ok(OPENAI_SERVICE),
        "gemini" => Ok(crate::gemini::SERVICE),
        _ => Err("지원하지 않는 AI입니다.".into()),
    }
}
fn load_key(provider: &str) -> Option<String> {
    match provider {
        "claude" => ai::load_key(), "gemini" => ai::load_gemini_key(),
        "openai" => keyring::Entry::new(OPENAI_SERVICE, "api-key").ok()?.get_password().ok().filter(|k| !k.is_empty()),
        _ => None,
    }
}

#[tauri::command]
pub fn generation_state(app: AppHandle) -> Value { snapshot(&app) }

#[tauri::command]
pub fn generation_save_key(provider: String, key: String) -> Result<(), String> {
    let service = service(&provider)?;
    let key = key.trim();
    if key.is_empty() || key.len() > 4096 || key.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("API 키를 확인하세요. 키 안에 공백이나 줄바꿈이 있으면 안 됩니다.".into());
    }
    keyring::Entry::new(service, "api-key").map_err(|_| "자격 증명 저장소를 열 수 없습니다.")?
        .set_password(key).map_err(|_| "API 키를 저장하지 못했습니다. 자격 증명 관리자 접근을 확인하세요.".into())
}

#[tauri::command]
pub async fn generation_connect(app: AppHandle, provider: String) -> Result<(), String> {
    let codex = match provider.as_str() { "claude" => false, "openai" => true,
        _ => return Err("Gemini는 API 키로 연결해 주세요.".into()) };
    tauri::async_runtime::spawn_blocking(move || ai::connect_subscription(&app, codex)).await.map_err(|_| "AI 연결이 중단됐습니다.")?
}

fn resource(app: &AppHandle, name: &str) -> Result<PathBuf, String> {
    let relative = format!("resources/generation/{name}");
    if let Ok(p) = app.path().resolve(&relative, tauri::path::BaseDirectory::Resource) {
        if p.is_file() { return Ok(p); }
    }
    if let Some(p) = std::env::current_exe().ok().and_then(|p| p.parent().map(|p| p.join(&relative))).filter(|p| p.is_file()) { return Ok(p); }
    #[cfg(debug_assertions)]
    {
        let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(&relative);
        if p.is_file() { return Ok(p); }
    }
    Err("영상 생성 도구를 찾을 수 없습니다. EasyCut을 다시 설치하세요.".into())
}
fn catalog(app: &AppHandle) -> Result<Value, String> {
    let p = resource(app, "skills.json")?;
    let value: Value = serde_json::from_str(&std::fs::read_to_string(p).map_err(|_| "제작 스킬을 읽지 못했습니다.")?)
        .map_err(|_| "제작 스킬을 읽지 못했습니다.")?;
    Ok(value.get("catalog").or_else(|| value.get("skills")).cloned().unwrap_or_else(|| json!([])))
}
#[tauri::command]
pub fn generation_catalog(app: AppHandle) -> Result<Value, String> { catalog(&app) }

fn node_path() -> Option<PathBuf> {
    if let Some(p) = tools::find_tool("node") { return Some(p); }
    for variable in ["ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"] {
        if let Some(base) = std::env::var_os(variable) {
            let p = PathBuf::from(base).join(if variable == "LOCALAPPDATA" { "Programs/nodejs/node.exe" } else { "nodejs/node.exe" });
            if p.is_file() { return Some(p); }
        }
    }
    None
}
fn browser_path() -> Option<PathBuf> {
    let mut candidates = vec![];
    for variable in ["ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"] {
        if let Some(base) = std::env::var_os(variable) {
            for relative in ["Google/Chrome/Application/chrome.exe", "Microsoft/Edge/Application/msedge.exe"] {
                candidates.push(PathBuf::from(&base).join(relative));
            }
        }
    }
    #[cfg(target_os = "macos")]
    candidates.extend(["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"].map(PathBuf::from));
    candidates.into_iter().find(|p| p.is_file())
}
fn worker_input(action: &str, directory: &Path) -> Value {
    let mut input = json!({"action":action,"jobDir":directory,"runtimeDir":tools::app_data().join("video-runtime-v1")});
    for (name, path) in [("browser", browser_path()), ("ffmpeg", tools::find_tool("ffmpeg")),
        ("ffprobe", tools::find_tool("ffprobe")), ("claude", ai::claude_binary()), ("codex", ai::codex_binary())] {
        if let Some(path) = path { input[name] = json!(path); }
    }
    input
}

#[tauri::command]
pub async fn generation_capabilities(app: AppHandle) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let skills = catalog(&app)?;
        let Some(node) = node_path() else {
            return Ok(json!({"providers":{"claude":{"hasKey":load_key("claude").is_some(),"installed":ai::claude_binary().is_some(),"subscriptionReady":false},
                "openai":{"hasKey":load_key("openai").is_some(),"installed":ai::codex_binary().is_some(),"subscriptionReady":false},
                "gemini":{"hasKey":load_key("gemini").is_some()}},"runtime":{"node":false,"npm":false,"browser":browser_path().is_some()},"skills":skills}));
        };
        let directory = tools::app_data().join("generated-videos");
        std::fs::create_dir_all(&directory).map_err(|_| "영상 작업 폴더를 만들지 못했습니다.")?;
        let mut result = run_worker(&app, &node, worker_input("status", &directory), None, Duration::from_secs(100))?;
        for provider in ["claude", "openai", "gemini"] {
            if !result["providers"][provider].is_object() { result["providers"][provider] = json!({}); }
            result["providers"][provider]["hasKey"] = json!(load_key(provider).is_some());
        }
        result["skills"] = skills;
        Ok(result)
    }).await.map_err(|_| "연결 상태를 확인하지 못했습니다.".to_string())?
}

#[tauri::command]
pub fn generation_start(app: AppHandle, request: Request) -> Result<Value, String> {
    request.validate()?;
    let node = node_path().ok_or("Node.js가 필요합니다. nodejs.org에서 LTS 버전을 설치한 뒤 다시 시도하세요.")?;
    let id = Id::new().to_string();
    let directory = tools::app_data().join("generated-videos").join(&id);
    std::fs::create_dir_all(&directory).map_err(|_| "영상 작업 폴더를 만들지 못했습니다.")?;
    let mut input = worker_input("preview", &directory);
    input["request"] = serde_json::to_value(&request).map_err(|_| "영상 설명을 확인하세요.")?;
    if request.access == "api" {
        let key = load_key(&request.provider).ok_or("선택한 AI의 API 키를 먼저 저장하세요.")?;
        input["apiKey"] = json!(key);
    }
    let token = {
        let state = app.state::<Generation>();
        let mut inner = state.0.lock().unwrap();
        if inner.state.busy { return Err("진행 중인 영상 작업을 마치거나 중지한 뒤 다시 시도하세요.".into()); }
        inner.token = inner.token.wrapping_add(1);
        inner.state = Snapshot { busy:true,status:"영상 미리보기를 준비하는 중…".into(),job_id:Some(id),request:Some(request),..Snapshot::default() };
        inner.directory = Some(directory);
        inner.token
    };
    notify(&app);
    start_worker(app.clone(), node, input, token, false);
    Ok(snapshot(&app))
}

fn matching_directory(app: &AppHandle, job_id: &str) -> Result<PathBuf, String> {
    let state = app.state::<Generation>();
    let inner = state.0.lock().unwrap();
    if inner.state.job_id.as_deref() != Some(job_id) { return Err("현재 영상 작업을 다시 선택하세요.".into()); }
    inner.directory.clone().ok_or("영상 작업 폴더가 없습니다.".into())
}
#[tauri::command]
pub fn generation_render(app: AppHandle, job_id: String) -> Result<Value, String> {
    let node = node_path().ok_or("Node.js를 찾을 수 없습니다.")?;
    let directory = matching_directory(&app, &job_id)?;
    let token = {
        let state = app.state::<Generation>();
        let mut inner = state.0.lock().unwrap();
        if inner.state.busy || inner.state.previews.len()!=4 || inner.state.output_path.is_some() {
            return Err("샘플 4장을 확인한 뒤 전체 렌더링을 누르세요.".into());
        }
        inner.token=inner.token.wrapping_add(1);inner.state.busy=true;inner.state.error=None;
        inner.state.status="확인한 코드로 영상을 렌더링하는 중…".into();inner.token
    };
    notify(&app);
    start_worker(app.clone(),node,worker_input("render",&directory),token,true);
    Ok(snapshot(&app))
}
#[tauri::command]
pub fn generation_cancel(app: AppHandle) { cancel(&app); }

fn safe_job_path(directory: &Path, path: &str) -> Result<PathBuf, String> {
    let root=directory.canonicalize().map_err(|_| "영상 작업 폴더를 확인하지 못했습니다.")?;
    let path=PathBuf::from(path).canonicalize().map_err(|_| "생성한 파일을 찾을 수 없습니다.")?;
    if !path.starts_with(&root) || !path.is_file() { return Err("영상 작업에 속하지 않는 파일입니다.".into()); }
    Ok(path)
}
fn accept_result(app:&AppHandle,token:u64,result:Value,render:bool)->Result<(),String>{
    let state=app.state::<Generation>();let mut inner=state.0.lock().unwrap();
    if inner.token!=token { return Err("중지됨".into()); }
    let directory=inner.directory.as_ref().ok_or("영상 작업 폴더가 없습니다.")?;
    let reported=result["jobDir"].as_str().ok_or("영상 작업 결과가 올바르지 않습니다.")?;
    if directory.canonicalize().ok()!=PathBuf::from(reported).canonicalize().ok(){return Err("영상 작업 폴더가 일치하지 않습니다.".into());}
    if render {
        let path=result["outputPath"].as_str().ok_or("완성된 영상이 없습니다.")?;
        let path=safe_job_path(directory,path)?;
        if path.file_name().and_then(|n|n.to_str())!=Some("render.mp4"){return Err("완성된 영상 파일을 확인하지 못했습니다.".into());}
        let asset=media::probe(&path)?;
        let request=inner.state.request.as_ref().ok_or("영상 설정이 없습니다.")?;
        if asset.kind!=MediaKind::Video || (asset.duration-request.duration).abs()>2.0/request.fps as f64 ||
            asset.width as u32!=request.width || asset.height as u32!=request.height { return Err("완성된 영상의 길이·크기가 요청과 다릅니다.".into()); }
        inner.state.output_path=Some(path.to_string_lossy().into_owned());
        inner.state.status="영상이 완성됐습니다. 재생해 보고 타임라인에 추가하세요.".into();
    }else{
        let previews=result["previews"].as_array().ok_or("샘플 프레임을 확인하지 못했습니다.")?;
        if previews.len()!=4{return Err("샘플 이미지 4장을 만들지 못했습니다.".into());}
        let paths=previews.iter().map(|v|safe_job_path(directory,v.as_str().unwrap_or(""))).collect::<Result<Vec<_>,_>>()?;
        if paths.iter().any(|p|p.extension().and_then(|e|e.to_str())!=Some("png")){return Err("샘플 이미지 형식이 올바르지 않습니다.".into());}
        inner.state.previews=paths.iter().map(|p|p.to_string_lossy().into_owned()).collect();
        inner.state.applied_skills=result["skills"].as_array().cloned().unwrap_or_default();
        inner.state.applied_skill_reason=result["skillReason"].as_str().unwrap_or("").chars().take(500).collect();
        inner.state.status="샘플 4장을 확인한 뒤 전체 렌더링을 누르세요.".into();
    }
    inner.state.busy=false;inner.control=None;Ok(())
}
fn start_worker(app:AppHandle,node:PathBuf,input:Value,token:u64,render:bool){
    std::thread::spawn(move||{
        let result=run_worker(&app,&node,input,Some(token),if render {Duration::from_secs(1900)}else{Duration::from_secs(1400)});
        let outcome=result.and_then(|v|accept_result(&app,token,v,render));
        if let Err(error)=outcome{
            let state=app.state::<Generation>();let mut inner=state.0.lock().unwrap();
            if inner.token==token{inner.state.busy=false;inner.state.error=Some(error);inner.state.status="영상 생성 실패".into();inner.control=None;}
        }
        notify(&app);
    });
}

#[tauri::command]
pub async fn generation_import(app:AppHandle,job_id:String)->Result<Value,String>{
    let directory=matching_directory(&app,&job_id)?;
    let output={let state=app.state::<Generation>();let inner=state.0.lock().unwrap();
        if inner.state.busy{return Err("진행 중인 영상 작업을 마친 뒤 추가하세요.".into());}
        inner.state.output_path.clone().ok_or("먼저 전체 영상을 렌더링하세요.")?};
    let path=safe_job_path(&directory,&output)?;
    let asset=tauri::async_runtime::spawn_blocking(move||media::probe(&path)).await.map_err(|_|"영상 파일을 확인하지 못했습니다.")??;
    if asset.kind!=MediaKind::Video||asset.duration<=0.0{return Err("가져올 수 있는 영상 파일이 아닙니다.".into());}
    {let state=app.state::<AppState>();let mut editor=state.editor.lock().unwrap();
        editor.apply(|project|{
            if project.duration()==0.0{project.canvas_width=asset.width;project.canvas_height=asset.height;}
            let end=project.tracks.first().map(|t|t.clips.iter().map(|c|c.end()).fold(0.0,f64::max)).unwrap_or(0.0);
            project.assets.push(asset.clone());project.insert(&asset,0,end,5.0);
        });
    }
    Ok(emit_state(&app))
}
#[tauri::command]
pub fn generation_open(app:AppHandle,job_id:String,kind:String)->Result<(),String>{
    let directory=matching_directory(&app,&job_id)?;
    let path=if kind=="folder"||kind=="code"{directory}else{
        let state=app.state::<Generation>();let inner=state.0.lock().unwrap();
        let value=if kind=="video"{inner.state.output_path.as_deref()}else{
            kind.strip_prefix("preview-").and_then(|s|s.parse::<usize>().ok()).filter(|&n|(1..=4).contains(&n)).and_then(|n|inner.state.previews.get(n-1).map(String::as_str))
        }.ok_or("열 파일이 없습니다.")?;
        safe_job_path(&directory,value)?
    };
    #[cfg(windows)]
    {tools::command(Path::new("explorer.exe")).arg(&path).spawn().map_err(|_|"파일을 열지 못했습니다.")?;}
    #[cfg(target_os="macos")]
    {tools::command(Path::new("/usr/bin/open")).arg(&path).spawn().map_err(|_|"파일을 열지 못했습니다.")?;}
    Ok(())
}

// The parent reserves the child's PID until wait(). The worker reads stdin only
// after it has been assigned to this job/group, so its browser/CLI descendants
// cannot escape process ownership by launching before assignment.
struct ProcessTree{
    pid:u32,
    #[cfg(windows)] job:usize,
}
impl ProcessTree{
    fn attach(child:&Child)->Result<Self,String>{
        #[cfg(windows)]
        unsafe{
            use std::os::windows::io::AsRawHandle;
            use windows_sys::Win32::Foundation::CloseHandle;
            use windows_sys::Win32::System::JobObjects::*;
            let job=CreateJobObjectW(std::ptr::null(),std::ptr::null());
            if job.is_null(){return Err("영상 작업 프로세스를 준비하지 못했습니다.".into());}
            let mut info:JOBOBJECT_EXTENDED_LIMIT_INFORMATION=std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if SetInformationJobObject(job,JobObjectExtendedLimitInformation,&info as *const _ as *const _,std::mem::size_of_val(&info) as u32)==0 ||
                AssignProcessToJobObject(job,child.as_raw_handle() as _)==0{
                CloseHandle(job);return Err("영상 작업 프로세스를 격리하지 못했습니다.".into());
            }
            return Ok(Self{pid:child.id(),job:job as usize});
        }
        #[cfg(not(windows))]
        Ok(Self{pid:child.id()})
    }
    fn terminate(&self){
        #[cfg(windows)]unsafe{windows_sys::Win32::System::JobObjects::TerminateJobObject(self.job as _,1);}
        #[cfg(unix)]unsafe{unsafe extern "C" {fn kill(pid:i32,sig:i32)->i32;}kill(-(self.pid as i32),9);}
    }
}
impl Drop for ProcessTree{
    fn drop(&mut self){
        #[cfg(windows)]unsafe{windows_sys::Win32::Foundation::CloseHandle(self.job as _);}
    }
}

fn run_worker(app:&AppHandle,node:&Path,input:Value,token:Option<u64>,timeout:Duration)->Result<Value,String>{
    let worker=resource(app,"worker.cjs")?;
    let mut command=ai::agent_command(node);
    command.arg(worker).current_dir(tools::app_data()).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(unix)]unsafe{
        use std::os::unix::process::CommandExt;
        command.pre_exec(||{unsafe extern "C"{fn setsid()->i32;}if setsid()<0{Err(std::io::Error::last_os_error())}else{Ok(())}});
    }
    let mut child=command.spawn().map_err(|_|"Node.js를 실행하지 못했습니다. LTS 버전을 설치한 뒤 다시 시도하세요.")?;
    let control=match ProcessTree::attach(&child){Ok(c)=>Arc::new(c),Err(e)=>{let _=child.kill();let _=child.wait();return Err(e);}};
    if let Some(token)=token{
        let state=app.state::<Generation>();let mut inner=state.0.lock().unwrap();
        if inner.token!=token{control.terminate();let _=child.wait();return Err("중지됨".into());}
        inner.control=Some(control.clone());
    }
    let secret=input["apiKey"].as_str().unwrap_or("").to_string();
    let payload=serde_json::to_vec(&input).map_err(|_|"영상 생성 요청을 준비하지 못했습니다.")?;
    let mut stdin=child.stdin.take().unwrap();
    let writer=std::thread::spawn(move||{let _=stdin.write_all(&payload);});
    let stdout=child.stdout.take().unwrap();let stderr=child.stderr.take().unwrap();
    let (tx,rx)=std::sync::mpsc::channel::<Result<Value,String>>();
    let reader=std::thread::spawn(move||{
        let mut reader=std::io::BufReader::new(stdout.take((MAX_OUTPUT + 1) as u64));let mut total=0usize;let mut line=Vec::new();
        loop{
            line.clear();
            let count=match std::io::BufRead::read_until(&mut reader,b'\n',&mut line){Ok(n)=>n,Err(_)=>{let _=tx.send(Err("영상 작업 응답을 읽지 못했습니다.".into()));break;}};
            if count==0{break;}total=total.saturating_add(count);
            if total>MAX_OUTPUT{let _=tx.send(Err("영상 작업 응답이 2MB를 초과했습니다.".into()));break;}
            if let Ok(event)=serde_json::from_slice::<Value>(&line){let _=tx.send(Ok(event));}
        }
    });
    let errors=std::thread::spawn(move||{let mut reader=stderr;let mut tail=Vec::new();let mut chunk=[0u8;4096];
        loop{match reader.read(&mut chunk){Ok(0)|Err(_)=>break,Ok(n)=>{tail.extend_from_slice(&chunk[..n]);if tail.len()>32768{tail.drain(..tail.len()-32768);}}}}tail});
    let began=Instant::now();let mut result=None;let mut failure=None;
    let status=loop{
        for event in rx.try_iter(){match event{
            Err(e)=>failure=Some(e),Ok(event)=>match event["event"].as_str(){
                Some("result")=>result=Some(event["result"].clone()),
                Some("error")=>failure=Some(event["error"].as_str().unwrap_or("영상 생성에 실패했습니다.").chars().take(1500).collect()),
                Some("progress")=>if let Some(token)=token{let state=app.state::<Generation>();let mut inner=state.0.lock().unwrap();
                    if inner.token==token{inner.state.status=event["status"].as_str().unwrap_or("").chars().take(500).collect();drop(inner);notify(app);}},
                _=>{},
            }
        }}
        let cancelled=token.is_some_and(|t|app.state::<Generation>().0.lock().unwrap().token!=t);
        if cancelled||failure.is_some()||began.elapsed()>timeout{
            if cancelled{failure=Some("중지됨".into());}else if failure.is_none(){failure=Some("영상 작업 시간이 초과되었습니다. 다시 시도하세요.".into());}
            control.terminate();break child.wait().ok();
        }
        match child.try_wait(){Ok(Some(status))=>break Some(status),Err(_)=>{failure=Some("영상 작업이 중단됐습니다.".into());control.terminate();break child.wait().ok();},Ok(None)=>std::thread::sleep(Duration::from_millis(40))}
    };
    control.terminate();let _=writer.join();let _=reader.join();let _=errors.join();
    // Drain events written immediately before the process exited.
    for event in rx.try_iter(){if let Err(error)=&event{failure=Some(error.clone());}if let Ok(event)=event{if event["event"]=="result"{result=Some(event["result"].clone());}else if event["event"]=="error"{failure=Some(event["error"].as_str().unwrap_or("영상 생성에 실패했습니다.").chars().take(1500).collect());}}}
    if let Some(token)=token{let state=app.state::<Generation>();let mut inner=state.0.lock().unwrap();if inner.token==token{inner.control=None;}}
    if let Some(mut error)=failure{if !secret.is_empty(){error=error.replace(&secret,"[API 키]");}return Err(error);}
    if !status.is_some_and(|s|s.success()){return Err("영상 생성 도구가 중단됐습니다. Node.js·Chrome 또는 Edge와 연결 상태를 확인하세요.".into());}
    result.ok_or("영상 작업 결과를 받지 못했습니다. 다시 시도하세요.".into())
}

#[cfg(test)]
mod tests{
    use super::*;
    #[test]fn validates_parity_and_denies_unsupported_access(){
        let mut r=Request{prompt:"설명 애니메이션".into(),..Request::default()};assert!(r.validate().is_ok());
        r.provider="gemini".into();assert!(r.validate().is_err());r.access="api".into();assert!(r.validate().is_ok());
        r.duration=f64::NAN;assert!(r.validate().is_err());r.duration=20.0;r.width=641;assert!(r.validate().is_err());
    }
    #[test]fn rejects_model_command_and_path_injection(){
        let mut r=Request{prompt:"영상".into(),..Request::default()};for name in ["x; calc.exe","../model","model\nkey","a?key=x",""]{r.model=name.into();assert!(r.validate().is_err());}
    }
    #[test]fn credential_services_are_separate(){
        assert_ne!(service("claude").unwrap(),service("openai").unwrap());assert_ne!(service("gemini").unwrap(),service("openai").unwrap());assert!(service("invalid").is_err());
    }
    #[test]fn subscription_login_does_not_accept_api_billing(){
        assert!(ai::subscription_status(false,r#"{"loggedIn":true,"authMethod":"claude.ai"}"#));
        assert!(!ai::subscription_status(false,r#"{"loggedIn":true,"authMethod":"api_key"}"#));
        assert!(ai::subscription_status(true,"Logged in using ChatGPT"));assert!(!ai::subscription_status(true,"Logged in using an API key"));
    }

    #[cfg(windows)]
    #[test]
    fn job_object_cancels_descendants_even_after_parent_exit() {
        // The only terminated processes are created by this test. stdin is the
        // launch gate: assigning the job happens before any descendant exists.
        struct Scratch(PathBuf);
        impl Drop for Scratch {
            fn drop(&mut self) {
                for _ in 0..10 {
                    if std::fs::remove_dir_all(&self.0).is_ok() { break; }
                    std::thread::sleep(Duration::from_millis(20));
                }
            }
        }
        struct OwnedChild { child: Child, tree: ProcessTree }
        impl Drop for OwnedChild {
            fn drop(&mut self) {
                self.tree.terminate();
                let _ = self.child.kill();
                let _ = self.child.wait();
            }
        }
        let node = node_path().expect("This Windows test requires Node.js (provided by CI setup-node)");
        let scratch = Scratch(std::env::temp_dir().join(format!("easycut-job-tree-{}", Id::new())));
        std::fs::create_dir_all(&scratch.0).unwrap();
        let script = r#"
          const {spawn}=require('node:child_process');
          let input=''; process.stdin.setEncoding('utf8');
          process.stdin.on('data',chunk=>input+=chunk);
          process.stdin.on('end',()=>{
            const request=JSON.parse(input);
            const source="const fs=require('node:fs');const beat=()=>fs.appendFileSync(process.argv[1],'x');beat();setInterval(beat,25);";
            spawn(process.execPath,['-e',source,request.heartbeat],{stdio:'ignore',windowsHide:true});
            if(request.parentExitsFirst) process.exit(0);
            setInterval(()=>{},1000);
          });
        "#;
        for parent_exits_first in [false, true] {
            let heartbeat = scratch.0.join(if parent_exits_first { "orphan.txt" } else { "running.txt" });
            let mut child = tools::command(&node).args(["-e", script]).stdin(Stdio::piped())
                .stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
            let tree = match ProcessTree::attach(&child) {
                Ok(tree) => tree,
                Err(error) => { let _ = child.kill(); let _ = child.wait(); panic!("{error}"); }
            };
            let mut owned = OwnedChild { child, tree };
            let payload = serde_json::to_vec(&json!({"heartbeat":heartbeat,"parentExitsFirst":parent_exits_first})).unwrap();
            owned.child.stdin.take().unwrap().write_all(&payload).unwrap();
            let deadline = Instant::now() + Duration::from_secs(8);
            while std::fs::read(&heartbeat).ok().filter(|b|!b.is_empty()).is_none() && Instant::now()<deadline {
                std::thread::sleep(Duration::from_millis(25));
            }
            assert!(heartbeat.is_file(), "The test-created descendant must start before cancellation");
            let first = std::fs::read(&heartbeat).unwrap();
            std::thread::sleep(Duration::from_millis(100));
            assert_ne!(first,std::fs::read(&heartbeat).unwrap(), "The descendant must be alive before cancellation");
            if parent_exits_first {
                let deadline = Instant::now() + Duration::from_secs(3);
                while owned.child.try_wait().unwrap().is_none() && Instant::now()<deadline {
                    std::thread::sleep(Duration::from_millis(20));
                }
                assert!(owned.child.try_wait().unwrap().is_some(), "The parent must already have exited in the orphan case");
            } else {
                assert!(owned.child.try_wait().unwrap().is_none());
            }
            owned.tree.terminate();
            let deadline = Instant::now() + Duration::from_secs(3);
            while owned.child.try_wait().unwrap().is_none() && Instant::now()<deadline {
                std::thread::sleep(Duration::from_millis(20));
            }
            assert!(owned.child.try_wait().unwrap().is_some(), "The test parent must terminate");
            std::thread::sleep(Duration::from_millis(150));
            let stopped = std::fs::read(&heartbeat).unwrap();
            std::thread::sleep(Duration::from_millis(200));
            assert_eq!(stopped,std::fs::read(&heartbeat).unwrap(), "Job cancellation must stop the descendant heartbeat");
        }
    }
}
