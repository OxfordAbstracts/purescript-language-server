export const getDocuments = (documents) => () => documents.all();
export const getDocument = (documents) => (uri) => () => documents.get(uri);
export const onDidSaveDocument = (documents) => (f) => () => documents.onDidSave((p) => f(p)());
export const onDidOpenDocument = (documents) => (f) => () => documents.onDidOpen((p) => f(p)());
export const onDidCloseDocument = (documents) => (f) => () => documents.onDidClose((p) => f(p)());
export const onDidChangeContent = (documents) => (f) => () => documents.onDidChangeContent((p) => f(p)());
