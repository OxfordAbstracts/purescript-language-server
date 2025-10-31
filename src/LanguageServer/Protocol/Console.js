export const log = (conn) => (s) => () => conn.console.log(s);
export const info = (conn) => (s) => () => conn.console.info(s);
export const warn = (conn) => (s) => () => conn.console.warn(s);
export const error = (conn) => (s) => () => conn.console.error(s);
