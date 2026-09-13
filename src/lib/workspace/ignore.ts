export function isNoisePath(path: string) {
  return /(^|\/)(node_modules|\.git|dist|build|\.next|coverage|vendor)(\/|$)/.test(path);
}
