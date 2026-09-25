// 윈도우 릴리스에서 콘솔 창을 띄우지 않는다
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    let args: Vec<String> = std::env::args().collect();
    // 외부 AI(Claude/Codex)가 실행하는 MCP 서버 모드: 창 없이 표준 입출력으로 동작
    if args.iter().any(|a| a == "--mcp") {
        easycut_app::run_mcp();
        return;
    }
    if let Some(i) = args.iter().position(|a| a == "--selftest") {
        let dir = args.get(i + 1).map(std::path::PathBuf::from).unwrap_or_else(|| std::env::temp_dir().join("easycut-selftest"));
        std::process::exit(easycut_app::selftest(&dir));
    }
    easycut_app::run()
}
