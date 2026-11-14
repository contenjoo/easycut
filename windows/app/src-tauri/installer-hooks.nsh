; 보이는 이름을 "OK Cut"으로.
; productName(EasyCut)은 설치 폴더·제거 정보·업데이트를 잇는 내부 이름이라 그대로 두고,
; 시작 메뉴·바탕화면 바로가기와 '앱 및 기능' 표시 이름만 바꾼다.

!macro OKCUT_RENAME_LNK DIR
  ${If} ${FileExists} "${DIR}\${PRODUCTNAME}.lnk"
    Delete "${DIR}\OK Cut.lnk"
    Rename "${DIR}\${PRODUCTNAME}.lnk" "${DIR}\OK Cut.lnk"
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTINSTALL
  !insertmacro OKCUT_RENAME_LNK "$SMPROGRAMS"
  ${If} $AppStartMenuFolder != ""
    !insertmacro OKCUT_RENAME_LNK "$SMPROGRAMS\$AppStartMenuFolder"
  ${EndIf}
  !insertmacro OKCUT_RENAME_LNK "$DESKTOP"
  WriteRegStr SHCTX "${UNINSTKEY}" "DisplayName" "OK Cut"
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  ; 업데이트 중에는 바로가기를 남겨 둔다 (새 설치가 그대로 이어 쓴다)
  ${If} $UpdateMode <> 1
    Delete "$SMPROGRAMS\OK Cut.lnk"
    ${If} $AppStartMenuFolder != ""
      Delete "$SMPROGRAMS\$AppStartMenuFolder\OK Cut.lnk"
    ${EndIf}
    Delete "$DESKTOP\OK Cut.lnk"
  ${EndIf}
!macroend
