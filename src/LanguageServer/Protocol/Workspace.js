import { CodeLensRefreshRequest, } from "vscode-languageserver/node.js";
export const codeLensRefresh = (conn) => () => conn.sendRequest(CodeLensRefreshRequest.type);
