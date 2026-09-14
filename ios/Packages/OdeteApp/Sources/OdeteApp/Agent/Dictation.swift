import AVFoundation
import Speech
import SwiftUI

/// Ditado no próprio aparelho. Transcreve enquanto a pessoa fala e vai escrevendo
/// no rascunho; nada sai do iPad quando o modelo de fala local está disponível.
@MainActor
@Observable
final class Dictation {
    /// Transcrição corrente, já com o texto que existia antes na frente.
    private(set) var texto = ""
    private(set) var running = false
    var error: String?

    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var base = ""

    /// Liga ou desliga. `atual` é o que já está escrito no campo.
    func toggle(atual: String) {
        if running {
            stop()
        } else {
            start(atual: atual)
        }
    }

    func start(atual: String) {
        guard !running else { return }
        error = nil
        base = atual.trimmingCharacters(in: .whitespacesAndNewlines)
        texto = atual
        Task { @MainActor in
            guard await autorizado() else {
                error = "permita o microfone e o reconhecimento de fala nos Ajustes do iPad"
                return
            }
            comecar()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Fora do MainActor de propósito: o Speech responde numa fila própria e a
    /// continuação presa ao ator principal derrubava o app.
    private nonisolated func autorizado() async -> Bool {
        let fala: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard fala == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    private func comecar() {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "pt_BR")) ?? SFSpeechRecognizer(),
              rec.isAvailable
        else {
            error = "ditado indisponível neste aparelho"
            return
        }
        do {
            let sessao = AVAudioSession.sharedInstance()
            try sessao.setCategory(.record, mode: .measurement, options: .duckOthers)
            try sessao.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
            request = req
            // O tap roda em thread de áudio; o pedido só recebe amostras por aqui.
            nonisolated(unsafe) let destino = req
            let entrada = engine.inputNode
            entrada.removeTap(onBus: 0)
            // `@Sendable` aqui não é enfeite: sem isso a closure herda o MainActor e o
            // Swift derruba o app quando a thread de áudio a chama.
            let receberAudio: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
                destino.append(buffer)
            }
            entrada.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: entrada.outputFormat(forBus: 0),
                block: receberAudio
            )
            engine.prepare()
            try engine.start()
            running = true
            let prefixo = base.isEmpty ? "" : base + " "
            let receber: @Sendable (String?, Bool) -> Void = { [weak self] trecho, fim in
                Task { @MainActor in
                    guard let self else { return }
                    if let trecho {
                        self.texto = prefixo + trecho
                    }
                    if fim {
                        self.stop()
                    }
                }
            }
            // Mesmo motivo do tap: o reconhecedor responde fora do ator principal.
            let aoTranscrever: @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void = { resultado, erro in
                receber(
                    resultado?.bestTranscription.formattedString,
                    erro != nil || (resultado?.isFinal ?? false)
                )
            }
            task = rec.recognitionTask(with: req, resultHandler: aoTranscrever)
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }
}
