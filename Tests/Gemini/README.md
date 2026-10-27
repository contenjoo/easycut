# Gemini adapter checks

Run without credentials or network calls from the repository root:

```sh
swiftc -parse-as-library Sources/EasyCut/AI/GeminiClient.swift Tests/Gemini/main.swift -o /tmp/easycut-gemini-tests
/tmp/easycut-gemini-tests
```

Uses URLProtocol fixtures to check the actual HTTP request, tool schema conversion,
Korean function arguments, preservation of model content/signatures, and error handling.
Does not prove Google model availability, quotas, real model editing quality, or keychain/UI behavior.

Manual check after building the app: select Gemini, open Google AI Studio, paste a personal
key, save and check the connection, then ask to add a title at 0 seconds in a disposable project.
Verify the title appears and undo restores the project. Try a wrong key and check the useful error.
Never put keys in test fixtures, source control, or screenshots.
