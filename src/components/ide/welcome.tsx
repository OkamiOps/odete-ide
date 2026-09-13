import { enterWorkspace } from "@/lib/workspace/chrome";

export function Welcome() {
  return (
    <div className="welcome" role="dialog" aria-label="Colo">
      <div className="welcome-inner">
        <p className="welcome-kicker">COLO</p>
        <h1>No colo.</h1>
        <p>Editor, git, terminal e agente no próprio dispositivo. Sem outra máquina ligada.</p>
        <button type="button" className="welcome-go" onClick={enterWorkspace}>
          Entrar no workspace
        </button>
        <div className="welcome-meta">
          <span>no próprio iPad</span>
          <span>preview ao vivo</span>
          <span>agente no dispositivo</span>
        </div>
      </div>
    </div>
  );
}
