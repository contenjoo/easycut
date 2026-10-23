import Foundation

extension AITools {
    static let recordingDefinitions: [[String: Any]] = [
        tool("list_recording_targets", "화면·창과 카메라·마이크 ID 조회. 화면 녹화 권한 필요. 좌표는 포인트, 화면 왼쪽 위 기준."),
        tool("start_recording", "별도 원본 녹화 시작. 현재 프로젝트 불변. 기본 무음·카메라 끔. 반환된 session_id로 조회·정지. 클릭 강조는 원본에 굽지 않고 JSON 좌표로 저장.", [
            "target": ["type": "string", "enum": ["window", "display", "area"]],
            "window_id": num("list_recording_targets의 창 ID"),
            "display_id": num("화면 ID. display/area 필수"),
            "x": num("영역 x"), "y": num("영역 y"), "width": num("영역 너비"), "height": num("영역 높이"),
            "fps": ["type": "integer", "enum": [24, 30, 60]],
            "camera": ["type": "boolean"], "microphone": ["type": "boolean"],
            "system_audio": ["type": "boolean"], "highlight_clicks": ["type": "boolean"],
            "camera_id": str("선택 장치 ID"), "microphone_id": str("선택 장치 ID")
        ], required: ["target"]),
        tool("get_recording_status", "녹화 상태·경과 시간·마지막 완료 결과 조회. 앱 재시작 전까지 보존.", ["session_id": str("선택. 특정 세션 확인")]),
        tool("stop_recording", "지정한 자동 녹화 세션 정지·저장 완료까지 대기. 같은 세션 재호출 안전. UI에서 시작한 녹화는 제어하지 않음.", ["session_id": str("start_recording에서 반환한 ID")], required: ["session_id"])
    ]

    @MainActor
    static func executeRecording(_ name: String, _ input: [String: Any], store: EditorStore) async -> (String, Bool)? {
        guard recordingDefinitions.contains(where: { $0["name"] as? String == name }) else { return nil }
        do {
            let value = try await store.recording.automation.call(name, input)
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            return (String(decoding: data, as: UTF8.self), value["state"] as? String == "failed")
        } catch {
            let data = try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])
            return (data.map { String(decoding: $0, as: UTF8.self) } ?? "녹화 오류", true)
        }
    }
}
