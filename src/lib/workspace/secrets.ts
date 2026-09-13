export async function persistAuth() {
  const { useChrome } = await import("./chrome");
  const { useProjects } = await import("./projects");
  const c = useChrome.getState();
  const p = useProjects.getState();
  if (!c.claudeAuth && !c.openaiAuth && !p.github) {
    const existing = await readSecrets();
    if (existing && (existing.github || existing.claudeAuth || existing.openaiAuth)) return;
  }
  await writeSecrets({
    github: p.github,
    claudeAuth: c.claudeAuth,
    openaiAuth: c.openaiAuth,
  });
}

export async function restoreAuth() {
  const s = await readSecrets();
  if (!s) return;
  const { useChrome } = await import("./chrome");
  const { useProjects } = await import("./projects");
  const c = useChrome.getState();
  if (s.claudeAuth && !c.claudeAuth?.access) useChrome.setState({ claudeAuth: s.claudeAuth });
  if (s.openaiAuth && !c.openaiAuth?.access) useChrome.setState({ openaiAuth: s.openaiAuth });
  if (s.github && !useProjects.getState().github) useProjects.setState({ github: s.github });
}