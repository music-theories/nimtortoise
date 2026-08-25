
proc next_provideInlayHints(self: JsObject, document: JsObject, viewPort: JsObject, token: JsObject): Promise[JsObject] {.importjs: "#(@)".}
proc provideInlayHints(document: JsObject, viewPort: JsObject, token: JsObject, next: JsObject): Promise[seq[InlayHint]] {.async.}=
  var hintsToReturn = newSeq[InlayHint]()
  let jsInlayHints = next_provideInlayHints(next, document, viewPort, token).await
  let decorationType: VscodeTextEditorDecorationType = vscode.window.createTextEditorDecorationType(
    VscodeDecorationRenderOptions(
      textDecoration: "underline #0CAFFF"
    )
  )
  let doc = document.to(VscodeTextDocument)
  let uri = doc.fileName  
  if uri in ext.propagatedDecorations:
    for decoration in ext.propagatedDecorations[uri]:
      decoration.dispose()
  
  if jsInlayHints.isNull or jsInlayHints.isUndefined:
    return hintsToReturn

  let inlayHints = jsInlayHints.to(seq[InlayHint])

  var decorationRanges: seq[VscodeDecorationOptions] = @[]
  let propagatedExceptionSymbol = vscode.workspace.getConfiguration("nimTortoise").getStr("inlayHints.exceptionHints.hintStringLeft")
  for hint in inlayHints:
    if hint.label == propagatedExceptionSymbol:
      # console.log("🔔 found. Skipping", hint)
      let wordRange: VscodeRange = doc.getWordRangeAtPosition(hint.position)
      let pos: VscodePosition = hint.position      
      decorationRanges.add(VscodeDecorationOptions(
        range: wordRange,
        hoverMessage: hint.tooltip
      ))
      if uri notin ext.propagatedDecorations:
        ext.propagatedDecorations[uri] = newSeq[VscodeTextEditorDecorationType]()
      ext.propagatedDecorations[uri].add(decorationType)
    else:
      hintsToReturn.add(hint)
  
  if decorationRanges.len > 0:
    let editor = vscode.window.activeTextEditor
    if not editor.isNil:
      editor.setDecorations(decorationType, decorationRanges)
  
  return hintsToReturn