//! 녹화 중 마우스 클릭 기록 (맥 RecordController.startClickCapture). 녹화 시간과 함께 화면 기준 0~1 좌표로 모은다.
//! 윈도우에서는 마우스 버튼 상태를 60번/초 확인한다 (전역 후크 없이).
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Default)]
pub struct Clicks {
    running: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    marks: Arc<Mutex<Vec<(f64, f64, f64)>>>,
}

/// rect: 녹화하는 모니터 (x, y, 너비, 높이) 물리 픽셀
pub fn start(c: &Clicks, rect: (f64, f64, f64, f64)) {
    c.running.store(true, Ordering::SeqCst);
    c.paused.store(false, Ordering::SeqCst);
    c.marks.lock().unwrap().clear();
    let (running, paused, marks) = (c.running.clone(), c.paused.clone(), c.marks.clone());
    std::thread::spawn(move || {
        let t0 = Instant::now();
        let mut paused_total = Duration::ZERO;
        let mut pause_began: Option<Instant> = None;
        let mut was_down = false;
        while running.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(16));
            if paused.load(Ordering::SeqCst) {
                pause_began.get_or_insert_with(Instant::now);
                continue;
            }
            if let Some(p) = pause_began.take() {
                paused_total += p.elapsed();
            }
            let Some((down, x, y)) = cursor() else { continue };
            if down && !was_down {
                let (rx, ry, rw, rh) = rect;
                if x >= rx && y >= ry && x < rx + rw && y < ry + rh {
                    let t = (t0.elapsed() - paused_total).as_secs_f64();
                    marks.lock().unwrap().push((t, (x - rx) / rw, (y - ry) / rh));
                }
            }
            was_down = down;
        }
    });
}

pub fn pause(c: &Clicks, on: bool) {
    c.paused.store(on, Ordering::SeqCst);
}

/// 멈추고 모은 클릭을 맥 형식 [{t, x, y}]으로
pub fn stop(c: &Clicks) -> Value {
    c.running.store(false, Ordering::SeqCst);
    let marks = c.marks.lock().unwrap().clone();
    json!(marks.into_iter().map(|(t, x, y)| json!({ "t": t, "x": x, "y": y })).collect::<Vec<_>>())
}

#[cfg(windows)]
fn cursor() -> Option<(bool, f64, f64)> {
    use windows_sys::Win32::Foundation::POINT;
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON, VK_RBUTTON};
    use windows_sys::Win32::UI::WindowsAndMessaging::GetCursorPos;
    unsafe {
        let down = (GetAsyncKeyState(VK_LBUTTON as i32) as u16 & 0x8000) != 0 || (GetAsyncKeyState(VK_RBUTTON as i32) as u16 & 0x8000) != 0;
        let mut p = POINT { x: 0, y: 0 };
        if GetCursorPos(&mut p) == 0 {
            return None;
        }
        Some((down, p.x as f64, p.y as f64))
    }
}

#[cfg(not(windows))]
fn cursor() -> Option<(bool, f64, f64)> {
    None
}
