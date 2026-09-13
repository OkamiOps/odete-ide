import { enterWorkspace } from "@/lib/workspace/chrome";

export function Welcome() {
  return (
    <div className="welcome" role="dialog" aria-label="Odete">
      <div className="welcome-glow" aria-hidden />
      <div className="welcome-inner">
        <img className="welcome-icon" src="/brand/odete-icon.png?v=4" width={168} height={168} alt="" />
        <img className="welcome-word" src="/brand/odete-wordmark.png?v=6" alt="Odete" />
        <p className="welcome-kicker">IDE para iPad e iPhone</p>
        <p className="welcome-line">Ideias se sentem mais em casa aqui.</p>
        <button type="button" className="welcome-go" onClick={enterWorkspace}>
          Entrar
        </button>
        <p className="welcome-meta">código · criar · em qualquer lugar</p>
      </div>
    </div>
  );
}
