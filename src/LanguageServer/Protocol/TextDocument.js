export const getText = (document) => () => document.getText();
export const getTextAtRange = (document) => (range) => () => document.getText(range);
export const getUri = (document) => document.uri;
export const getLanguageId = (document) => document.languageId;
export const getVersion = (document) => () => document.version;
export const getLineCount = (document) => () => document.lineCount;
export const offsetAtPosition = (document) => (pos) => () => document.offsetAt(pos);
export const positionAtOffset = (document) => (offset) => () => document.positionAt(offset);
