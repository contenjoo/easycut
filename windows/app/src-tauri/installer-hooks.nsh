; Tauri's productName, registry key and install folder have always been EasyCut.
; Keep shortcuts created by 0.10.0 usable when the updater preserves them.
!macro EASYCUT_MIGRATE_SHORTCUT DIR
  ${If} ${FileExists} "${DIR}\OK Cut.lnk"
    ${If} ${FileExists} "${DIR}\${PRODUCTNAME}.lnk"
      Delete "${DIR}\OK Cut.lnk"
    ${Else}
      Rename "${DIR}\OK Cut.lnk" "${DIR}\${PRODUCTNAME}.lnk"
    ${EndIf}
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTINSTALL
  !insertmacro EASYCUT_MIGRATE_SHORTCUT "$SMPROGRAMS"
  ${If} $AppStartMenuFolder != ""
    !insertmacro EASYCUT_MIGRATE_SHORTCUT "$SMPROGRAMS\$AppStartMenuFolder"
  ${EndIf}
  !insertmacro EASYCUT_MIGRATE_SHORTCUT "$DESKTOP"
  WriteRegStr SHCTX "${UNINSTKEY}" "DisplayName" "${PRODUCTNAME}"
!macroend
