import { URI } from "vscode-uri";
export const uriToFilename = (uri) => () => URI.parse(uri).fsPath;
export const filenameToUri = (filename) => () => URI.file(filename).toString();
