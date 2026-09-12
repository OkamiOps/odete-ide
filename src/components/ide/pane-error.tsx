import { Component, type ErrorInfo, type ReactNode } from "react";

export class PaneError extends Component<
  { name: string; children: ReactNode },
  { message: string }
> {
  state = { message: "" };

  static getDerivedStateFromError(err: Error) {
    return { message: err.message || "falha" };
  }

  componentDidCatch(err: Error, info: ErrorInfo) {
    console.error(this.props.name, err, info.componentStack);
  }

  render() {
    if (this.state.message) {
      return (
        <div className="flex h-full min-h-0 flex-col p-4">
          <p className="text-sm text-danger">{this.props.name} quebrou.</p>
          <p className="mt-2 font-mono text-xs text-fg-muted">{this.state.message}</p>
          <button
            type="button"
            className="chip mt-4 self-start"
            onClick={() => this.setState({ message: "" })}
          >
            Tentar de novo
          </button>
        </div>
      );
    }
    return <div className="pane-fill">{this.props.children}</div>;
  }
}
