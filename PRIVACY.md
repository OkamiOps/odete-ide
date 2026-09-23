<div align="center">

# Privacy Policy — Odete IDE

**English** · [Português](#português-brasil) · [Deutsch](#deutsch) · [Français](#français) · [Español](#español)

_Last updated: 23 September 2026_

</div>

---

## English

**Odete IDE does not collect any data.**

There is no Odete account, no Odete server and no analytics. Nothing about you, your
projects or your usage is sent to us, because there is nowhere for it to be sent.

### What stays on your device

Your projects, files, git repositories, commit history, terminal history, editor settings,
chosen language and agent conversations are all stored on your device, inside the app's
container or in the Files app folder you choose. They are included in your own iCloud or
local backups, under your control, and nowhere else.

### When data leaves your device, and where it goes

Odete only makes network requests when you ask it to, and always directly to the service
you chose. Odete is not in the middle and keeps no copy.

| You do this | The request goes to | What is sent |
|---|---|---|
| Clone, fetch or push a repository | The git host you typed (GitHub, GitLab, your own server) | Your git credentials and the repository contents |
| Use the GitHub pane (pull requests, CI) | `api.github.com` | Your GitHub token and the API request |
| `npm install` | `registry.npmjs.org` and the registry you configured | The package names being resolved |
| Send a message to the coding agent | The provider you signed in to — Anthropic, OpenAI, xAI, or an OpenAI-compatible endpoint you typed | Your prompt, plus the file contents and command output the agent requested |
| Send a message to a cloud model | `models.dev/api.json` (a public catalog of models) | Nothing about you: a plain download of the catalog, at most once a day, to learn each model's context window and output limit |
| Load a preview whose packages are not installed | `esm.sh` | The names and versions of the modules being imported |
| Open a link in Safari from the preview pane | The site you opened | Whatever that site normally receives |

You choose every one of these. An offline Odete never contacts anything.

### Credentials

API keys, OAuth tokens and git passwords you enter are stored in the iOS Keychain on your
device. They are used to authenticate against the service you gave them for, and are never
transmitted anywhere else. Removing the account in Settings deletes them.

### The coding agent

The agent runs against **your** provider account, with **your** key. Your conversations
and code are subject to that provider's privacy policy, not ours. Read theirs, since it is
the one that applies:

- [Anthropic](https://www.anthropic.com/legal/privacy)
- [OpenAI](https://openai.com/policies/privacy-policy)
- [xAI](https://x.ai/legal/privacy-policy)

If you use an OpenAI-compatible endpoint of your own, the policy is whatever you run there.

### Children

Odete is a developer tool. It contains no ads, no in-app purchases, no user accounts and no
social features, and it collects nothing from anyone, including children.

### Changes

If this policy ever changes, the new version replaces this file in the repository and the
date above changes with it. There is no notification to send, since we have no way to
contact you.

### Contact

Open an issue at [github.com/OkamiOps/odete-ide/issues](https://github.com/OkamiOps/odete-ide/issues).

---

## Português (Brasil)

**O Odete IDE não coleta nenhum dado.**

Não existe conta Odete, não existe servidor Odete e não existe telemetria. Nada sobre você,
seus projetos ou seu uso é enviado para nós, porque não há para onde enviar.

### O que fica no seu aparelho

Seus projetos, arquivos, repositórios git, histórico de commits, histórico do terminal,
preferências do editor, idioma escolhido e as conversas com o agente ficam todos no seu
aparelho, dentro do contêiner do app ou na pasta do app Arquivos que você escolher. Entram
nos seus backups do iCloud ou locais, sob seu controle, e em nenhum outro lugar.

### Quando um dado sai do aparelho, e para onde vai

O Odete só faz requisição de rede quando você pede, e sempre direto para o serviço que você
escolheu. O Odete não fica no meio e não guarda cópia.

| Você faz isso | A requisição vai para | O que é enviado |
|---|---|---|
| Clonar, buscar ou enviar um repositório | O servidor git que você digitou (GitHub, GitLab, o seu) | Suas credenciais git e o conteúdo do repositório |
| Usar o painel do GitHub (pull requests, CI) | `api.github.com` | Seu token do GitHub e a requisição |
| `npm install` | `registry.npmjs.org` e o registro que você configurou | Os nomes dos pacotes sendo resolvidos |
| Mandar uma mensagem para o agente | O provedor em que você entrou — Anthropic, OpenAI, xAI ou um endpoint compatível com OpenAI que você digitou | Seu texto, mais o conteúdo dos arquivos e a saída dos comandos que o agente pediu |
| Mandar uma mensagem para um modelo na nuvem | `models.dev/api.json` (catálogo público de modelos) | Nada sobre você: só o download do catálogo, no máximo uma vez por dia, para saber a janela de contexto e o limite de saída de cada modelo |
| Abrir um preview cujos pacotes não estão instalados | `esm.sh` | Os nomes e versões dos módulos importados |
| Abrir um link no Safari a partir do preview | O site que você abriu | O que aquele site normalmente recebe |

Cada uma dessas coisas é escolha sua. Um Odete offline não contata nada.

### Credenciais

Chaves de API, tokens OAuth e senhas de git que você digita ficam na Keychain do iOS, no seu
aparelho. São usadas para autenticar no serviço para o qual você as deu, e nunca são
transmitidas para outro lugar. Remover a conta nos Ajustes apaga essas credenciais.

### O agente

O agente roda na **sua** conta de provedor, com a **sua** chave. Suas conversas e seu código
seguem a política de privacidade daquele provedor, não a nossa. Leia a deles, que é a que
vale:

- [Anthropic](https://www.anthropic.com/legal/privacy)
- [OpenAI](https://openai.com/policies/privacy-policy)
- [xAI](https://x.ai/legal/privacy-policy)

Se você usa um endpoint compatível com OpenAI seu, a política é a de quem você hospeda.

### Crianças

O Odete é uma ferramenta de desenvolvimento. Não tem anúncio, não tem compra dentro do app,
não tem conta de usuário e não tem recurso social, e não coleta nada de ninguém, inclusive
de crianças.

### Mudanças

Se esta política mudar, a versão nova substitui este arquivo no repositório e a data acima
muda junto. Não há notificação a enviar, já que não temos como contatar você.

### Contato

Abra uma issue em [github.com/OkamiOps/odete-ide/issues](https://github.com/OkamiOps/odete-ide/issues).

---

## Deutsch

**Odete IDE erhebt keinerlei Daten.**

Es gibt kein Odete-Konto, keinen Odete-Server und keine Analytik. Nichts über Sie, Ihre
Projekte oder Ihre Nutzung wird an uns gesendet, weil es kein Ziel dafür gibt.

### Was auf Ihrem Gerät bleibt

Ihre Projekte, Dateien, Git-Repositories, Commit-Historie, Terminal-Historie,
Editoreinstellungen, gewählte Sprache und die Gespräche mit dem Agenten liegen auf Ihrem
Gerät, im Container der App oder in dem Ordner der Dateien-App, den Sie wählen. Sie sind in
Ihren eigenen iCloud- oder lokalen Backups enthalten, unter Ihrer Kontrolle, und sonst
nirgendwo.

### Wann Daten das Gerät verlassen, und wohin

Odete stellt nur dann eine Netzwerkanfrage, wenn Sie es verlangen, und immer direkt an den
Dienst, den Sie gewählt haben. Odete sitzt nicht dazwischen und behält keine Kopie.

| Sie tun dies | Die Anfrage geht an | Was gesendet wird |
|---|---|---|
| Ein Repository klonen, holen oder pushen | Den Git-Host, den Sie eingegeben haben (GitHub, GitLab, Ihren eigenen) | Ihre Git-Zugangsdaten und den Inhalt des Repositories |
| Das GitHub-Panel nutzen (Pull Requests, CI) | `api.github.com` | Ihr GitHub-Token und die Anfrage |
| `npm install` | `registry.npmjs.org` und die von Ihnen konfigurierte Registry | Die Namen der aufzulösenden Pakete |
| Eine Nachricht an den Agenten senden | Den Anbieter, bei dem Sie angemeldet sind — Anthropic, OpenAI, xAI oder einen von Ihnen eingegebenen OpenAI-kompatiblen Endpunkt | Ihren Text sowie die Dateiinhalte und Befehlsausgaben, die der Agent angefordert hat |
| Eine Nachricht an ein Cloud-Modell senden | `models.dev/api.json` (ein öffentlicher Modellkatalog) | Nichts über Sie: nur der Download des Katalogs, höchstens einmal am Tag, um Kontextfenster und Ausgabelimit jedes Modells zu kennen |
| Eine Vorschau laden, deren Pakete nicht installiert sind | `esm.sh` | Die Namen und Versionen der importierten Module |
| Aus der Vorschau einen Link in Safari öffnen | Die Website, die Sie geöffnet haben | Was diese Website ohnehin erhält |

Jede dieser Handlungen ist Ihre Entscheidung. Ein Odete ohne Netz kontaktiert nichts.

### Zugangsdaten

API-Schlüssel, OAuth-Tokens und Git-Passwörter, die Sie eingeben, liegen im iOS-Schlüsselbund
auf Ihrem Gerät. Sie dienen der Anmeldung bei genau dem Dienst, für den Sie sie angegeben
haben, und werden nirgendwo anders übertragen. Das Entfernen des Kontos in den Einstellungen
löscht sie.

### Der Agent

Der Agent läuft mit **Ihrem** Anbieterkonto und **Ihrem** Schlüssel. Für Ihre Gespräche und
Ihren Code gilt die Datenschutzerklärung dieses Anbieters, nicht unsere. Lesen Sie deren
Erklärung, denn sie ist die maßgebliche:

- [Anthropic](https://www.anthropic.com/legal/privacy)
- [OpenAI](https://openai.com/policies/privacy-policy)
- [xAI](https://x.ai/legal/privacy-policy)

Wenn Sie einen eigenen OpenAI-kompatiblen Endpunkt nutzen, gilt die Erklärung dessen, was Sie
dort betreiben.

### Kinder

Odete ist ein Entwicklerwerkzeug. Es enthält keine Werbung, keine In-App-Käufe, keine
Benutzerkonten und keine sozialen Funktionen, und es erhebt von niemandem Daten, auch nicht
von Kindern.

### Änderungen

Ändert sich diese Erklärung, ersetzt die neue Fassung diese Datei im Repository, und das
Datum oben ändert sich mit. Eine Benachrichtigung gibt es nicht, da wir keine Möglichkeit
haben, Sie zu kontaktieren.

### Kontakt

Eröffnen Sie ein Issue unter [github.com/OkamiOps/odete-ide/issues](https://github.com/OkamiOps/odete-ide/issues).

---

## Français

**Odete IDE ne collecte aucune donnée.**

Il n'y a pas de compte Odete, pas de serveur Odete et pas d'analytique. Rien sur vous, vos
projets ou votre usage ne nous est envoyé, car il n'y a nulle part où l'envoyer.

### Ce qui reste sur votre appareil

Vos projets, fichiers, dépôts git, historique de commits, historique du terminal, réglages
de l'éditeur, langue choisie et conversations avec l'agent restent sur votre appareil, dans
le conteneur de l'app ou dans le dossier de l'app Fichiers que vous choisissez. Ils font
partie de vos propres sauvegardes iCloud ou locales, sous votre contrôle, et nulle part
ailleurs.

### Quand des données quittent l'appareil, et vers où

Odete ne fait de requête réseau que lorsque vous le demandez, et toujours directement vers
le service que vous avez choisi. Odete n'est pas au milieu et n'en garde pas de copie.

| Vous faites ceci | La requête part vers | Ce qui est envoyé |
|---|---|---|
| Cloner, récupérer ou pousser un dépôt | L'hôte git que vous avez saisi (GitHub, GitLab, le vôtre) | Vos identifiants git et le contenu du dépôt |
| Utiliser le panneau GitHub (pull requests, CI) | `api.github.com` | Votre jeton GitHub et la requête |
| `npm install` | `registry.npmjs.org` et le registre que vous avez configuré | Les noms des paquets en cours de résolution |
| Envoyer un message à l'agent | Le fournisseur auquel vous êtes connecté — Anthropic, OpenAI, xAI, ou un point d'accès compatible OpenAI que vous avez saisi | Votre texte, ainsi que le contenu des fichiers et la sortie des commandes demandés par l'agent |
| Envoyer un message à un modèle dans le cloud | `models.dev/api.json` (un catalogue public de modèles) | Rien sur vous : seulement le téléchargement du catalogue, au plus une fois par jour, pour connaître la fenêtre de contexte et la limite de sortie de chaque modèle |
| Charger un aperçu dont les paquets ne sont pas installés | `esm.sh` | Les noms et versions des modules importés |
| Ouvrir un lien dans Safari depuis l'aperçu | Le site que vous avez ouvert | Ce que ce site reçoit habituellement |

Chacune de ces actions est votre choix. Un Odete hors ligne ne contacte rien.

### Identifiants

Les clés d'API, jetons OAuth et mots de passe git que vous saisissez sont stockés dans le
trousseau iOS, sur votre appareil. Ils servent à vous authentifier auprès du service pour
lequel vous les avez fournis, et ne sont jamais transmis ailleurs. Supprimer le compte dans
les Réglages les efface.

### L'agent

L'agent fonctionne avec **votre** compte fournisseur et **votre** clé. Vos conversations et
votre code relèvent de la politique de confidentialité de ce fournisseur, pas de la nôtre.
Lisez la leur, c'est celle qui s'applique :

- [Anthropic](https://www.anthropic.com/legal/privacy)
- [OpenAI](https://openai.com/policies/privacy-policy)
- [xAI](https://x.ai/legal/privacy-policy)

Si vous utilisez votre propre point d'accès compatible OpenAI, la politique est celle de ce
que vous y hébergez.

### Enfants

Odete est un outil de développement. Il ne contient ni publicité, ni achat intégré, ni
compte utilisateur, ni fonction sociale, et ne collecte rien de personne, y compris des
enfants.

### Modifications

Si cette politique change, la nouvelle version remplace ce fichier dans le dépôt et la date
ci-dessus change avec elle. Il n'y a pas de notification à envoyer, puisque nous n'avons
aucun moyen de vous contacter.

### Contact

Ouvrez une issue sur [github.com/OkamiOps/odete-ide/issues](https://github.com/OkamiOps/odete-ide/issues).

---

## Español

**Odete IDE no recopila ningún dato.**

No hay cuenta de Odete, no hay servidor de Odete y no hay analítica. Nada sobre ti, tus
proyectos o tu uso se nos envía, porque no hay adónde enviarlo.

### Lo que se queda en tu dispositivo

Tus proyectos, archivos, repositorios git, historial de commits, historial del terminal,
ajustes del editor, idioma elegido y las conversaciones con el agente se quedan en tu
dispositivo, dentro del contenedor de la app o en la carpeta de la app Archivos que elijas.
Entran en tus propias copias de seguridad de iCloud o locales, bajo tu control, y en ningún
otro sitio.

### Cuándo salen datos del dispositivo, y adónde van

Odete solo hace peticiones de red cuando se lo pides, y siempre directamente al servicio que
elegiste. Odete no está en medio y no guarda copia.

| Haces esto | La petición va a | Qué se envía |
|---|---|---|
| Clonar, traer o enviar un repositorio | El servidor git que escribiste (GitHub, GitLab, el tuyo) | Tus credenciales de git y el contenido del repositorio |
| Usar el panel de GitHub (pull requests, CI) | `api.github.com` | Tu token de GitHub y la petición |
| `npm install` | `registry.npmjs.org` y el registro que configuraste | Los nombres de los paquetes que se resuelven |
| Enviar un mensaje al agente | El proveedor en el que iniciaste sesión — Anthropic, OpenAI, xAI, o un endpoint compatible con OpenAI que escribiste | Tu texto, más el contenido de los archivos y la salida de los comandos que pidió el agente |
| Enviar un mensaje a un modelo en la nube | `models.dev/api.json` (un catálogo público de modelos) | Nada sobre ti: solo la descarga del catálogo, como mucho una vez al día, para conocer la ventana de contexto y el límite de salida de cada modelo |
| Cargar una vista previa cuyos paquetes no están instalados | `esm.sh` | Los nombres y versiones de los módulos importados |
| Abrir un enlace en Safari desde la vista previa | El sitio que abriste | Lo que ese sitio recibe normalmente |

Cada una de estas cosas la eliges tú. Un Odete sin conexión no contacta con nada.

### Credenciales

Las claves de API, los tokens OAuth y las contraseñas de git que escribes se guardan en el
Llavero de iOS, en tu dispositivo. Se usan para autenticarte en el servicio para el que las
diste, y nunca se transmiten a ningún otro sitio. Quitar la cuenta en Ajustes las borra.

### El agente

El agente funciona con **tu** cuenta de proveedor y **tu** clave. Tus conversaciones y tu
código se rigen por la política de privacidad de ese proveedor, no por la nuestra. Lee la
suya, que es la que se aplica:

- [Anthropic](https://www.anthropic.com/legal/privacy)
- [OpenAI](https://openai.com/policies/privacy-policy)
- [xAI](https://x.ai/legal/privacy-policy)

Si usas un endpoint compatible con OpenAI propio, la política es la de lo que alojes ahí.

### Menores

Odete es una herramienta de desarrollo. No tiene anuncios, ni compras dentro de la app, ni
cuentas de usuario, ni funciones sociales, y no recopila nada de nadie, incluidos los
menores.

### Cambios

Si esta política cambia, la versión nueva sustituye a este archivo en el repositorio y la
fecha de arriba cambia con ella. No hay notificación que enviar, ya que no tenemos forma de
contactarte.

### Contacto

Abre una issue en [github.com/OkamiOps/odete-ide/issues](https://github.com/OkamiOps/odete-ide/issues).
