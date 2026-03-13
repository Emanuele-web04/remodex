# Analisis en Profundidad del Sistema de Chat de Remodex

## Context

Analisis exhaustivo del sistema de chat: como renderiza mensajes, como gestiona las respuestas del agente, el flujo de datos completo desde la conexion WebSocket hasta la UI, persistencia, modelos de datos y patrones arquitectonicos.

---

## 1. Arquitectura General

El sistema de chat es una app iOS (SwiftUI + Observation framework) que se comunica con un bridge local via **WebSocket** usando el protocolo **JSON-RPC**. La arquitectura sigue un patron unidireccional:

```
WebSocket (NWConnection)
    -> CodexService (estado central, @Observable)
        -> ThreadTimelineState (estado por thread)
            -> TurnTimelineRenderSnapshot (snapshot inmutable para UI)
                -> TurnView -> TurnTimelineView -> MessageRow
```

### Archivos clave

| Capa | Archivo | Responsabilidad |
|------|---------|-----------------|
| Transporte | `Services/CodexService+Transport.swift` | WebSocket NWConnection, send/receive loop |
| Decodificacion | `Services/CodexService+Incoming.swift` | Decodifica JSON-RPC, enruta eventos por metodo |
| Asistente | `Services/CodexService+IncomingAssistant.swift` | Maneja deltas/start/completed del asistente |
| Mensajes | `Services/CodexService+Messages.swift` | Timeline por thread, merge streaming, persistencia |
| Turns | `Services/CodexService+ThreadsTurns.swift` | Operaciones thread/turn: crear, listar, iniciar |
| Estado central | `Services/CodexService.swift` | Container @Observable con todo el estado |
| Modelo | `Models/CodexMessage.swift` | Struct del mensaje |
| Modelo | `Models/CodexThread.swift` | Struct del thread/conversacion |
| Modelo | `Models/CodexImageAttachment.swift` | Adjuntos de imagen |
| Modelo | `Models/CodexCollaboration.swift` | Plan mode, structured input |
| Modelo | `Models/AIChangeSetModels.swift` | Changesets de codigo del asistente |
| Modelo | `Models/RPCMessage.swift` | Envelope JSON-RPC 2.0 |
| Persistencia | `Services/CodexMessagePersistence.swift` | Almacenamiento encriptado de mensajes |
| Persistencia | `Services/AIChangeSetPersistence.swift` | Almacenamiento de changesets |
| Vista orquestadora | `Views/Turn/TurnView.swift` | Compone timeline + composer + alertas |
| Vista timeline | `Views/Turn/TurnTimelineView.swift` | ScrollView con LazyVStack paginado |
| Vista container | `Views/Turn/TurnConversationContainerView.swift` | Wrapper que ensambla timeline + composer |
| Rows | `Views/Turn/TurnMessageComponents.swift` | MessageRow: renderiza cada tipo de mensaje |
| Reducer | `Views/Turn/TurnTimelineReducer.swift` | Ordena/deduplica/colapsa mensajes antes de render |
| Caches | `Views/Turn/TurnMessageCaches.swift` | LRU caches para parseo costoso (markdown, diffs, etc) |
| ViewModel | `Views/Turn/TurnViewModel.swift` | Estado local de la vista, acciones del usuario |
| Thinking | `Views/Turn/ThinkingDisclosureParser.swift` | Parseo de secciones colapsables de razonamiento |
| Comandos | `Views/Turn/CommandExecutionViews.swift` | Cards de ejecucion de comandos |
| File changes | `Views/Turn/TurnFileChangeSummaryParser.swift` | Parseo de cambios en archivos |
| Plan mode | `Views/Turn/TurnPlanModeComponents.swift` | Cards de plan mode |
| User input | `Views/Turn/StructuredUserInputCardView.swift` | Cards interactivas de input |
| Scroll | `Views/Turn/TurnScrollStateTracker.swift` | Tracking de viewport y auto-scroll |
| Env keys | `Views/Turn/TurnMessageEnvironmentKeys.swift` | Actions de commit, revert |

---

## 2. Capa de Transporte (WebSocket + JSON-RPC)

### Conexion

- **Protocolo**: WebSocket nativo via `NWConnection` (framework Network de Apple)
- **Archivo**: `CodexService+Transport.swift`
- **Metodo**: `establishWebSocketConnection(url:token:role:)` crea la conexion con timeout de 12s
- **Seguridad**: Soporta WSS (TLS), autenticacion via header `Authorization: Bearer` o `x-role`
- **Encriptacion adicional**: `secureWireText(for:)` aplica una capa de cifrado propia (AES-256-GCM) sobre el payload JSON-RPC antes de enviarlo
- **Auto-ping**: `webSocketOptions.autoReplyPing = true` mantiene la conexion viva

### Receive Loop

```
startReceiveLoop(with:)
  -> receiveNextMessage(on:) [recursivo]
      -> connection.receiveMessage { data, context, _, error in ... }
          -> processIncomingWireText(text)  // desencripta
              -> processIncomingText(text)  // decodifica JSON
                  -> decoder.decode(RPCMessage.self, from: payloadData)
                      -> handleIncomingRPCMessage(message)
```

### Tipos de mensajes RPC

1. **Notificaciones** (sin `id`): eventos push del servidor -> `handleNotification(method:params:)`
2. **Requests** (con `id` + `method`): solicitudes del servidor (ej: aprobaciones) -> `handleServerRequest(method:requestID:params:)`
3. **Responses** (con `id`, sin `method`): respuestas a peticiones del cliente -> resuelve `pendingRequests[key]` continuation

### Envio de mensajes

```swift
// Request-response con continuation
func sendRequest(method: String, params: JSONValue?) async throws -> RPCMessage {
    let requestID = UUID().uuidString
    pendingRequests[requestKey] = continuation
    try await sendMessage(request)
    // ... continuation se resume cuando llega response con mismo ID
}

// Fire-and-forget
func sendNotification(method: String, params: JSONValue?) async throws

// Respuesta a server request
func sendResponse(id: JSONValue, result: JSONValue) async throws
```

### Bridge (Node.js)

- **Archivo**: `phodex-bridge/src/bridge.js`
- Dos modos de transporte (`codex-transport.js`):
  - **Spawn mode**: lanza `codex app-server` local, comunica via stdin/stdout
  - **WebSocket mode**: conecta a endpoint WebSocket existente
- Forwarding bidireccional: Codex <-> Bridge <-> Relay <-> iPhone
- Reconnect con exponential backoff (hasta 5s)

---

## 3. Enrutamiento de Eventos Entrantes

**Archivo**: `CodexService+Incoming.swift:117-226`

El metodo `handleNotification(method:params:)` es el **router central**. Normaliza el nombre del metodo y despacha segun un switch exhaustivo:

### Eventos de Thread

| Metodo | Handler | Efecto |
|--------|---------|--------|
| `thread/started` | `handleThreadStarted` | Inserta thread en lista local, auto-selecciona si es el primero |
| `thread/name/updated` | `handleThreadNameUpdated` | Actualiza titulo en tiempo real |
| `thread/status/changed` | `handleThreadStatusChanged` | Cambia estado running/ready/failed |
| `thread/tokenUsage/updated` | `handleThreadTokenUsageUpdated` | Actualiza uso de context window |

### Eventos de Turn (turno = una interaccion usuario->agente)

| Metodo | Handler | Efecto |
|--------|---------|--------|
| `turn/started` | `handleTurnStarted` | Marca thread como running, registra turnId activo, mapea turn->thread |
| `turn/completed` | `handleTurnCompleted` | Limpia estado running, registra terminal state, haptic feedback |
| `turn/plan/updated` | `handleTurnPlanUpdated` | Actualiza plan mode steps |
| `turn/diff/updated` | `handleTurnDiffUpdated` | Actualiza diffs acumulados del turno |
| `turn/failed` | `handleErrorNotification` | Registra error del turno |

### Eventos de Streaming del Asistente

| Metodo | Handler | Efecto |
|--------|---------|--------|
| `item/agentMessage/delta` | `appendAgentDelta` | Append texto incremental al mensaje |
| `item/started` | `handleItemStarted` | Crea placeholder de mensaje streaming |
| `item/completed` | `appendCompletedAgentText` | Finaliza mensaje con texto canonico |

### Eventos de Reasoning/Thinking

| Metodo | Handler | Efecto |
|--------|---------|--------|
| `item/reasoning/summaryTextDelta` | `appendReasoningDelta` | Delta de pensamiento |
| `item/reasoning/summaryPartAdded` | `appendReasoningDelta` | Parte de razonamiento |
| `item/reasoning/textDelta` | `appendReasoningDelta` | Delta generico de razonamiento |

### Eventos de Tool Calls / File Changes / Commands

| Metodo | Handler | Efecto |
|--------|---------|--------|
| `item/fileChange/outputDelta` | `appendFileChangeDelta` | Delta de cambios en archivos |
| `item/commandExecution/outputDelta` | `appendCommandExecutionDelta` | Delta de ejecucion de comandos |
| `item/commandExecution/terminalInteraction` | `handleCommandExecutionTerminalInteraction` | Interaccion terminal |
| `item/toolCall/outputDelta` | `appendToolCallDelta` | Delta de llamadas a herramientas |
| `item/plan/delta` | `appendPlanDelta` | Delta de plan mode |

### Variantes legacy `codex/event/*`

| Metodo | Handler |
|--------|---------|
| `codex/event/agent_message_content_delta` | `appendAgentDelta` |
| `codex/event/agent_message_delta` | `appendAgentDelta` |
| `codex/event/item_completed` | `appendCompletedAgentText` |
| `codex/event/item_started` | `handleItemStarted` |
| `codex/event/exec_command_begin/output_delta/end` | `handleLegacyCodexNamedEvent` |
| `codex/event/turn_diff_updated` | `handleTurnDiffUpdated` |
| `codex/event/patch_apply_begin/end` | `handleLegacyPatchApplyMethod` |
| `codex/event` (envelope) | `handleLegacyCodexEnvelopeEvent` |

### Tolerancia a variantes

El sistema tiene **fallbacks robustos** que normalizan nombres de metodos no estandar:

- `handleFileChangeNotificationFallback`: detecta cualquier metodo que contenga "filechange"
- `handleToolCallNotificationFallback`: detecta cualquier metodo con "toolcall"
- `handleDiffNotificationFallback`: detecta metodos con "diff"

Cada fallback normaliza el metodo (lowercase, remove `_` y `-`) y detecta sub-tipos (delta, started, completed).

### Server Requests (aprobaciones)

| Metodo | Handler | Efecto |
|--------|---------|--------|
| `item/commandExecution/requestApproval` | Presenta `CodexApprovalRequest` | Auto-aprueba si `fullAccess` |
| `item/fileChange/requestApproval` | Presenta `CodexApprovalRequest` | Auto-aprueba si `fullAccess` |
| `item/tool/requestUserInput` | `handleStructuredUserInputRequest` | Muestra formulario interactivo |

---

## 4. Gestion de Respuestas del Agente (Streaming)

**Archivos**: `CodexService+IncomingAssistant.swift`, `CodexService+Messages.swift`

### Flujo completo de una respuesta

```
1. turn/started
   -> handleTurnStarted()
   -> Registra activeTurnIdByThread[threadId] = turnId
   -> markThreadAsRunning(threadId)
   -> threadIdByTurnID[turnId] = threadId
   -> Limpia protectedRunningFallback

2. item/started (type: agentMessage)
   -> handleItemStarted() -> beginAssistantMessage()
   -> Crea CodexMessage(role: .assistant, text: "", isStreaming: true)
   -> Registra streamingAssistantMessageByTurnID[key] = messageID
   -> NO se crea en turn/started para evitar orden incorrecto con thinking

3. item/agentMessage/delta (x N veces)
   -> appendAgentDelta() -> extractAssistantDeltaText() -> appendAssistantDelta()
   -> ensureStreamingAssistantMessage() crea placeholder si no existe
   -> mergeAssistantDelta(): concatena texto al mensaje existente
   -> messagesByThread[threadId][index].text += delta
   -> isStreaming = true
   -> persistMessages() [debounced] + updateCurrentOutput()

4. item/completed
   -> appendCompletedAgentText() -> completeAssistantMessage()
   -> Reemplaza texto con version canonica final del servidor
   -> isStreaming = false
   -> Registra fingerprint para deduplicacion (45s window)
   -> noteAssistantMessage() -> vincula con AIChangeSet si existe

5. turn/completed
   -> handleTurnCompleted()
   -> Limpia activeTurnIdByThread[threadId]
   -> recordTurnTerminalState(.completed/.failed/.stopped)
   -> clearRunningState() + haptic feedback
   -> Despacha turnos encolados si existen
```

### Resolucion de identidad (AssistantEventContext)

Cada evento del asistente pasa por `resolveAssistantEventContext()` que:

1. **Extrae `turnId`** de multiples ubicaciones:
   - `paramsObject["turnId"]` (directo)
   - `paramsObject["id"]` (legacy, si tiene `msg` o `event`)
   - `eventObject["turn"]["id"]` (nested)
   - `paramsObject["event"]["turn"]["id"]` (double-nested)

2. **Extrae `itemId`** de ~25 variantes:
   - `itemObject["id"]`, `itemObject["itemId"]`, `itemObject["item_id"]`
   - `itemObject["messageId"]`, `itemObject["message_id"]`
   - `paramsObject["itemId"]`, `paramsObject["item_id"]`
   - `paramsObject["item"]["id"]`, `paramsObject["item"]["itemId"]`
   - `eventObject["itemId"]`, `eventObject["item"]["id"]`
   - ...y mas variantes (camelCase, snake_case, nested)

3. **Resuelve `threadId`** directamente del payload o via `threadIdByTurnID[turnId]`

4. **Valida** coherencia antes de procesar

### Multi-item turns

Un turno puede contener multiples items del asistente (ej: thinking -> response -> thinking -> response).

Cuando `beginAssistantMessage` detecta un nuevo `itemId` para el mismo `turnId`:
- Marca el mensaje anterior como `isStreaming = false`
- Limpia el streaming key del turno
- Crea un nuevo `CodexMessage` para el nuevo item
- Preserva cada burbuja de texto independiente en el timeline

### Deduplicacion

- `assistantCompletionFingerprintByThread`: evita procesar el mismo texto final dos veces en 45s
- `normalizedMessageText()`: normaliza whitespace para comparacion de duplicados
- Merge inteligente en `completeAssistantMessage`: si ya existe un mensaje con el mismo texto, solo marca `isStreaming = false`
- `mergeLateReasoningDeltaIfPossible()`: merge silencioso de deltas de reasoning que llegan post-completion

---

## 5. Modelo de Datos

### CodexMessage (`Models/CodexMessage.swift`)

```swift
struct CodexMessage: Identifiable, Codable, Hashable, Sendable {
    let id: String                    // UUID
    let threadId: String              // Thread al que pertenece
    let role: CodexMessageRole        // .user | .assistant | .system
    var kind: CodexMessageKind        // .chat | .thinking | .fileChange | .commandExecution | .plan | .userInputPrompt
    var text: String                  // Contenido del mensaje
    let createdAt: Date
    var turnId: String?               // Turno al que pertenece
    var itemId: String?               // Item especifico dentro del turno
    var isStreaming: Bool             // true mientras llegan deltas
    var deliveryState: CodexMessageDeliveryState  // .pending | .confirmed | .failed
    var attachments: [CodexImageAttachment]
    var planState: CodexPlanState?
    var structuredUserInputRequest: CodexStructuredUserInputRequest?
    var orderIndex: Int               // Contador monotonico para orden estable
}
```

- **Roles**: `.user` (mensaje del usuario), `.assistant` (respuesta del agente), `.system` (thinking, file changes, commands, etc)
- **Kinds**: `.chat` (conversacion normal), `.thinking` (razonamiento), `.fileChange` (cambios de archivo), `.commandExecution` (ejecucion de comando), `.plan` (plan mode), `.userInputPrompt` (formulario interactivo)
- **Ordering**: `orderIndex` es un contador global monotonico (`CodexMessageOrderCounter.next()`) que garantiza orden de insercion estable sin depender de timestamps (que pueden tener drift)

### CodexThread (`Models/CodexThread.swift`)

```swift
struct CodexThread: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String?               // Titulo generado por el servidor
    var name: String?                // Nombre custom (AI/user rename)
    var preview: String?             // Preview del primer mensaje
    var createdAt: Date?
    var updatedAt: Date?
    var cwd: String?                 // Working directory del proyecto
    var metadata: [String: JSONValue]?
    var syncState: CodexThreadSyncState  // .live | .archivedLocal
}
```

- `displayTitle`: prioriza name > title > preview > "Conversation"
- `projectKey`: cwd normalizado para agrupar threads por proyecto
- `gitWorkingDirectory`: repo root para operaciones git
- Decodifica timestamps flexiblemente: ISO8601 (con/sin fracciones), Unix seconds, Unix milliseconds

### CodexImageAttachment (`Models/CodexImageAttachment.swift`)

```swift
struct CodexImageAttachment: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let thumbnailBase64JPEG: String   // Preview comprimido
    let payloadDataURL: String?       // Data URL de imagen completa
    let sourceURL: String?            // URL original
}
```

### AIChangeSet (`Models/AIChangeSetModels.swift`)

```swift
struct AIChangeSet {
    let id: String
    let threadId: String
    let turnId: String
    var assistantMessageId: String?
    var status: AIChangeSetStatus     // .collecting | .ready | .reverted | .failed | .notRevertable
    var fileChanges: [AIFileChange]   // Archivos modificados (create/update/delete)
    var forwardUnifiedPatch: String?  // Diff para aplicar
    var inverseUnifiedPatch: String?  // Diff para revertir
    var revertMetadata: AIChangeSetRevertMetadata?
}
```

### Modelos de Colaboracion (`Models/CodexCollaboration.swift`)

```swift
struct CodexPlanState: Codable, Hashable, Sendable {
    var explanation: String?
    var steps: [CodexPlanStep]
}

struct CodexPlanStep: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var description: String
    var status: CodexPlanStepStatus   // .pending | .inProgress | .completed
}

struct CodexStructuredUserInputRequest: Codable, Hashable, Sendable {
    let requestId: String
    let questions: [CodexStructuredUserInputQuestion]
}
```

### RPCMessage (`Models/RPCMessage.swift`)

```swift
struct RPCMessage: Codable {
    var jsonrpc: String?              // "2.0"
    var id: JSONValue?                // Request ID para pairing
    var method: String?               // Metodo RPC
    var params: JSONValue?            // Parametros
    var result: JSONValue?            // Resultado (response)
    var error: RPCError?              // Error (response)
}
```

### Estado central en CodexService

```swift
// --- Threads y mensajes ---
var threads: [CodexThread]
var messagesByThread: [String: [CodexMessage]]
var messageRevisionByThread: [String: Int]      // Token de mutacion por thread

// --- Estado de turns ---
var activeTurnIdByThread: [String: String]       // Turno activo por thread
var runningThreadIDs: Set<String>                // Threads ejecutando
var protectedRunningFallbackThreadIDs: Set<String> // Pre-turn running
var latestTurnTerminalStateByThread: [String: CodexTurnTerminalState]
var terminalStateByTurnID: [String: CodexTurnTerminalState]

// --- Streaming ---
var streamingAssistantMessageByTurnID: [String: String]  // turn/item -> messageID
var streamingSystemMessageByItemID: [String: String]      // item -> messageID
var commandExecutionDetailsByItemID: [String: CommandExecutionDetails]

// --- Mapeos ---
var threadIdByTurnID: [String: String]           // Inverso turn -> thread

// --- AI Changesets ---
var aiChangeSetsByID: [String: AIChangeSet]
var aiChangeSetIDByTurnID: [String: String]
var aiChangeSetIDByAssistantMessageID: [String: String]

// --- Sidebar badges ---
var readyThreadIDs: Set<String>
var failedThreadIDs: Set<String>

// --- UI state per thread (aislado) ---
var threadTimelineStateByThread: [String: ThreadTimelineState]
var stoppedTurnIDsByThread: [String: Set<String>]
```

### ThreadTimelineState

Estado aislado por thread para la UI, con snapshot inmutable:

```swift
@MainActor @Observable
final class ThreadTimelineState {
    let threadID: String
    var messages: [CodexMessage]
    var messageRevision: Int
    var activeTurnID: String?
    var isThreadRunning: Bool
    var latestTurnTerminalState: CodexTurnTerminalState?
    var stoppedTurnIDs: Set<String>
    var repoRefreshSignal: String?
    var renderSnapshot: TurnTimelineRenderSnapshot  // Snapshot inmutable para la vista
}
```

### TurnTimelineRenderSnapshot

```swift
struct TurnTimelineRenderSnapshot: Equatable {
    let threadID: String
    let messages: [CodexMessage]
    let timelineChangeToken: Int
    let activeTurnID: String?
    let isThreadRunning: Bool
    let latestTurnTerminalState: CodexTurnTerminalState?
    let stoppedTurnIDs: Set<String>
    let assistantRevertStatesByMessageID: [String: AssistantRevertPresentation]
    let repoRefreshSignal: String?
}
```

---

## 6. Persistencia

### CodexMessagePersistence (`Services/CodexMessagePersistence.swift`)

- **Encriptacion**: AES-256-GCM con clave simetrica almacenada en Keychain
- **Archivo**: `codex-message-history-v6.bin` (encriptado), con fallback a v5/v4/v3/v2 sin encriptar
- **Estructura**: `[String: [CodexMessage]]` — diccionario threadId -> array de mensajes
- **Filtrado**: Elimina mensajes `.userInputPrompt` antes de persistir (estado live-only)
- **Debounce**: `messagePersistenceDebounceTask` agrupa escrituras durante streaming
- **Carga**: Al inicializar, limpia flags stale (`isStreaming = false`) y seed de `CodexMessageOrderCounter`

### AIChangeSetPersistence (`Services/AIChangeSetPersistence.swift`)

- **Archivo**: `codex-ai-change-sets-v1.json` (sin encriptar)
- **Estructura**: Array de `AIChangeSet` ordenados por creacion
- **Proposito**: Metadata durable para revert de cambios entre relanzamientos

### Flujo de inicializacion (CodexService.init)

```
1. CodexMessagePersistence.load()
   -> Desencripta codex-message-history-v6.bin
   -> Deserializa [String: [CodexMessage]]
   -> Limpia isStreaming = false en todos los mensajes
   -> Seed CodexMessageOrderCounter.seed(from: loadedMessages)

2. AIChangeSetPersistence.load()
   -> Deserializa [AIChangeSet]
   -> Construye indices:
      - aiChangeSetsByID[id]
      - aiChangeSetIDByTurnID[turnId]
      - aiChangeSetIDByAssistantMessageID[messageId]

3. UserDefaults
   -> selectedModelId, selectedReasoningEffort, selectedServiceTier, selectedAccessMode

4. Keychain (SecureStore)
   -> relaySessionId, relayUrl, relayMacDeviceId, relayMacIdentityPublicKey
   -> relayProtocolVersion, lastAppliedBridgeOutboundSeq
   -> phoneIdentityState, trustedMacRegistry
```

---

## 7. Rendering Pipeline

### 7.1. TurnTimelineReducer (`Views/Turn/TurnTimelineReducer.swift`)

Antes de renderizar, los mensajes pasan por `TurnTimelineProjection` que:

1. **Elimina** system markers ocultos
2. **Ordena** intra-turno: user -> thinking -> assistant -> file changes
3. **Colapsa** thinking messages consecutivos en uno solo
4. **Elimina** duplicados de file change y assistant messages
5. **Detecta** turns multi-item con thinking/reasoning intercalado via `hasInterleavedAssistantThinkingFlow()`
6. **Preserva** orden cronologico dentro de multi-item turns (no reordena por rol)

### 7.2. TurnTimelineView (`Views/Turn/TurnTimelineView.swift`)

- `ScrollViewReader` + `LazyVStack` con spacing de 20pt
- **Paginacion**: 40 mensajes por pagina, carga lazy hacia arriba con boton
- **Auto-scroll**: 3 modos gestionados por `TurnScrollStateTracker`
  - `.followBottom`: sigue el final al llegar nuevos mensajes
  - `.anchorAssistantResponse`: ancla a la primera respuesta del asistente (usa `assistantResponseAnchorMessageID()`)
  - `.manual`: el usuario controla el scroll
- **Cooldown**: evita "scroll wars" durante deceleracion del scroll
- **Bottom threshold**: deteccion de "scrolled to bottom" con margen configurable

### 7.3. MessageRow (`Views/Turn/TurnMessageComponents.swift`)

Componente central que implementa `View` + `Equatable` para optimizar re-renders. Usa `MessageRowRenderModel` cacheado que agrupa todos los artefactos parseados.

#### User messages (`.user`)

- Burbuja derecha con fondo `Color(.tertiarySystemFill).opacity(0.8)`
- Border 1pt, corner radius 24pt (continuous)
- Padding: 12pt vertical, 16pt horizontal
- Font: `AppFont.body()`
- Muestra `UserAttachmentStrip` para imagenes adjuntas
- Renderiza **mention tokens**: `@archivo` en color azul, `$skill` en color
- Context menu: Copy + Retry
- Indicador de delivery state (pending spinner / failed badge)

#### Assistant messages (`.assistant`)

- Alineado a la izquierda, sin burbuja (full-width)
- **MarkdownTextView**: usa la libreria `Textual` con estilo GitHub (`.textual.structuredTextStyle(.gitHub)`)
- `TypingIndicator` (3 puntos animados con movimiento sinusoidal) mientras `isStreaming == true`
- Boton "Copy block" cuando la respuesta esta completa y no es un turno stopped
- Puede contener `CodeCommentDirectiveContent` (hallazgos de revision de codigo inline)
- Soporte de text selection via `.textual.textSelection(.enabled)`

#### System messages (`.system`) — despacho por `kind`

| Kind | Componente | Descripcion |
|------|-----------|-------------|
| `.thinking` | `ThinkingDisclosureView` | Secciones colapsables con parsing de anchors bold. Fuente mono italic. Label "Thinking..." |
| `.fileChange` | `fileChangeSystemView` | Path con additions/deletions, boton diff, linkified paths en azul |
| `.commandExecution` | `CommandExecutionStatusCard` | Comando + badge (running/completed/failed) + barra de color lateral. Tap abre detail sheet |
| `.plan` | `PlanSystemCard` | Explicacion + lista de pasos con iconos de status (pending/in-progress/completed) |
| `.userInputPrompt` | `StructuredUserInputCardView` | Radio buttons + freeform "Other" field + boton Submit |
| `.chat` | `defaultSystemView` | Texto sistema generico |

### 7.4. Caches de Rendering (`Views/Turn/TurnMessageCaches.swift`)

Sistema de **LRU caches thread-safe** para evitar reparsear contenido en cada render:

| Cache | Capacidad | Contenido |
|-------|-----------|-----------|
| `MessageRowRenderModelCache` | 512 | Modelo completo de rendering (agrupa todos los sub-caches) |
| `MarkdownRenderableTextCache` | 512 | Markdown transformado con `MarkdownTextFormatter` |
| `CommandExecutionStatusCache` | 256 | Estado de ejecucion parseado |
| `FileChangeSystemRenderCache` | 256 | Cambios de archivo parseados con `TurnFileChangeSummaryParser` |
| `CodeCommentDirectiveContentCache` | 256 | Hallazgos de revision de codigo |
| `ThinkingDisclosureContentCache` | 256 | Estructura de thinking con anchors colapsables |
| `PerFileDiffChunkCache` | 128 | Chunks de diff por archivo |
| `FileChangeGroupingCache` | 256 | Agrupacion de cambios de archivo |
| `DiffBlockDetectionCache` | 512 | Deteccion de bloques diff en texto |

Todos usan `NSLock` para thread safety y se limpian completamente por overflow (no LRU exacto de eviction individual).

### 7.5. Markdown Rendering

- **MarkdownTextView**: usa la libreria `Textual` (StructuredText markdown renderer)
- **MarkdownTextFormatter**: normaliza markdown antes del render
  - Convierte headings a bold
  - Linkifica rutas de archivos
  - Reemplaza referencias a skills
  - Detecta fenced code blocks e inline code
- **Perfiles**: `.assistantProse` (respuestas) y `.fileChangeSystem` (cambios)

---

## 8. Envio de Mensajes del Usuario

### Flujo completo

```
1. TurnComposerView captura input (texto + attachments + @mentions + $skills)
       |
2. TurnViewModel valida y prepara payload
   - Convierte images a CodexImageAttachment
   - Resuelve file mentions y skill mentions
   - Determina collaborationMode (default/plan)
       |
3. CodexService.appendUserMessage()
   - Crea CodexMessage(role: .user, deliveryState: .pending) INMEDIATAMENTE
   - UI optimista: el mensaje aparece al instante
       |
4. CodexService.startTurn()
   - Si no hay thread, crea uno via thread/start RPC
   - Envia turn/start RPC con: userInput, threadId, attachments, skillMentions, collaborationMode, serviceTier
       |
5. Servidor responde
   - turn/started notification -> deliveryState = .confirmed
   - O error -> deliveryState = .failed, habilita retry
```

### Turn Queueing

- Si ya hay un turno activo en el thread, el draft se almacena en `queuedTurnDraftsByThread[threadId]`
- Se despacha automaticamente cuando el turno actual completa
- `QueuePauseState` permite pausar la cola si hay errores repetidos
- Cada draft preserva texto, attachments y skill mentions

### Aprobaciones

- El servidor puede pedir aprobacion antes de ejecutar comandos/cambios de archivo
- Llega como `handleServerRequest(method: "item/commandExecution/requestApproval")`
- Se presenta como `pendingApproval: CodexApprovalRequest?` en la UI
- Si `selectedAccessMode == .fullAccess`, se auto-aprueba sin intervencion del usuario
- El usuario puede aceptar o rechazar via la UI

---

## 9. Gestion de Estado de Turns

### Ciclo de vida de un Turn

```
                 turn/start RPC enviado
                        |
                        v
    protectedRunningFallback = true (pre-turnId)
                        |
                        v
              turn/started notification
                        |
                        v
        activeTurnIdByThread[threadId] = turnId
        runningThreadIDs.insert(threadId)
        protectedRunningFallback = false
                        |
                        v
            streaming deltas (N eventos)
                        |
                        v
              turn/completed notification
                        |
                        v
        activeTurnIdByThread[threadId] = nil
        runningThreadIDs.remove(threadId)
        terminalStateByTurnID[turnId] = .completed/.failed/.stopped
```

### Estados terminales

- `.completed`: turno finalizado exitosamente
- `.failed`: turno fallo por error
- `.stopped`: turno interrumpido por el usuario

### Stop (interrupcion)

- Metodo: `interruptTurn(turnId:threadId:)`
- Si `activeTurnIdByThread[threadId]` esta vacio, consulta `thread/read` para resolver
- Envia `turn/interrupt` RPC request
- Registra `terminalStateByTurnID[turnId] = .stopped`
- Los turnos stopped **no muestran** boton de Copy en la UI

### Reconnect/Background Recovery

- Al reconectar: `refreshInFlightTurnState()` rehidrata estado del turno activo
- `prepareThreadForDisplay()` fuerza un `thread/read(force: true)` para sincronizar
- Los flags `isStreaming` se limpian al cargar desde disco (no sobreviven app relaunch)
- `shouldAutoReconnectOnForeground` permite reconexion automatica al volver al foreground
- `backgroundTurnGraceTaskID` mantiene un background task activo mientras hay turnos running

### Sync Loop (`CodexService+Sync.swift`)

3 tareas concurrentes de polling:
- **Thread list sync**: cada 20s (foreground) / 75s (background)
- **Active thread state sync**: cada 15s (foreground) / 90-12s (background, segun si hay turno running)
- **Running badge watcher**: cada 4s (foreground) / 15s (background)

---

## 10. Jerarquia Completa de Componentes

```
TurnView (orquestador principal)
  |
  +-- codex.timelineState(for: thread.id)
  |     +-- renderSnapshot: TurnTimelineRenderSnapshot (inmutable)
  |
  +-- TurnConversationContainerView
  |     |
  |     +-- TurnTimelineView<EmptyState, Composer>
  |     |     |
  |     |     +-- ScrollViewReader + LazyVStack (spacing: 20pt)
  |     |     |     |
  |     |     |     +-- [Pagination button - load earlier messages]
  |     |     |     |
  |     |     |     +-- ForEach(messages) { message in
  |     |     |     |     MessageRow(message:)
  |     |     |     |       |
  |     |     |     |       +-- [.user] -> userBubble(text:)
  |     |     |     |       |     +-- UserAttachmentStrip (imagenes)
  |     |     |     |       |     +-- Mention tokens (@file, $skill)
  |     |     |     |       |     +-- DeliveryState indicator
  |     |     |     |       |     +-- ContextMenu (Copy, Retry)
  |     |     |     |       |
  |     |     |     |       +-- [.assistant] -> assistantView(text:renderModel:)
  |     |     |     |       |     +-- CodeCommentDirectiveContent (review findings)
  |     |     |     |       |     +-- MarkdownTextView (Textual lib, GitHub style)
  |     |     |     |       |     +-- TypingIndicator (3 dots, sinusoidal)
  |     |     |     |       |     +-- CopyBlockButton
  |     |     |     |       |     +-- AssistantRevertButton
  |     |     |     |       |
  |     |     |     |       +-- [.system] -> routing by kind:
  |     |     |     |             +-- .thinking -> ThinkingDisclosureView
  |     |     |     |             |     +-- Collapsible sections
  |     |     |     |             |     +-- Mono italic font
  |     |     |     |             |
  |     |     |     |             +-- .fileChange -> fileChangeSystemView
  |     |     |     |             |     +-- File path (linkified)
  |     |     |     |             |     +-- +additions / -deletions
  |     |     |     |             |     +-- Diff button
  |     |     |     |             |
  |     |     |     |             +-- .commandExecution -> CommandExecutionStatusCard
  |     |     |     |             |     +-- Terminal icon + command text
  |     |     |     |             |     +-- Status badge (running/completed/failed)
  |     |     |     |             |     +-- Colored accent bar
  |     |     |     |             |     +-- Tap -> detail sheet
  |     |     |     |             |
  |     |     |     |             +-- .plan -> PlanSystemCard
  |     |     |     |             |     +-- Explanation text
  |     |     |     |             |     +-- Step list with status icons
  |     |     |     |             |
  |     |     |     |             +-- .userInputPrompt -> StructuredUserInputCardView
  |     |     |     |             |     +-- Questions with radio buttons
  |     |     |     |             |     +-- "Other" freeform field
  |     |     |     |             |     +-- Submit button
  |     |     |     |             |
  |     |     |     |             +-- .chat -> defaultSystemView
  |     |     |     |
  |     |     |     +-- [Scroll anchor (bottom)]
  |     |     |
  |     |     +-- TurnScrollStateTracker
  |     |
  |     +-- TurnComposerHostView
  |           +-- TurnComposerView
  |           |     +-- TurnComposerInputTextView (text field)
  |           |     +-- Attachment thumbnails
  |           |     +-- File autocomplete dropdown
  |           |     +-- Skill autocomplete dropdown
  |           |     +-- Send button
  |           |
  |           +-- TurnGitActionsToolbar
  |           |     +-- TurnGitBranchSelector
  |           |     +-- Commit & Push button
  |           |
  |           +-- Model selector
  |           +-- Reasoning effort selector
  |           +-- Plan mode toggle
  |
  +-- TurnViewAlertModifier
  |     +-- Approval dialog (accept/reject commands)
  |     +-- Error alerts
  |
  +-- TurnViewLifecycleModifier
        +-- Scene phase handling (foreground/background)
        +-- Thread preparation on appear
        +-- Focus management
```

---

## 11. Flujo de Datos Completo (End-to-End)

```
┌────────────────────────────────────────────┐
│  Bridge Local (Node.js)                    │
│  phodex-bridge/src/bridge.js               │
│  ├── Spawn mode: stdin/stdout a codex CLI  │
│  └── WebSocket mode: ws:// a app-server    │
└──────────────┬─────────────────────────────┘
               │ WebSocket (relay)
               ▼
┌────────────────────────────────────────────┐
│  NWConnection (WebSocket)                  │
│  CodexService+Transport.swift              │
│  receiveNextMessage() → recursivo          │
└──────────────┬─────────────────────────────┘
               │ processIncomingWireText()
               │ → desencripta AES-256-GCM
               │ → decoder.decode(RPCMessage)
               ▼
┌────────────────────────────────────────────┐
│  handleIncomingRPCMessage()                │
│  CodexService+Incoming.swift               │
│  ├── Notification → handleNotification()   │
│  ├── Request → handleServerRequest()       │
│  └── Response → resume continuation        │
└──────────────┬─────────────────────────────┘
               │ switch(method)
               ▼
┌────────────────────────────────────────────┐
│  Event Handlers                            │
│  ├── turn/started → activeTurnId set       │
│  ├── item/started → beginAssistantMessage  │
│  ├── item/delta → appendAssistantDelta     │
│  ├── item/completed → completeAssistant    │
│  └── turn/completed → recordTerminalState  │
└──────────────┬─────────────────────────────┘
               │ mutate messagesByThread
               │ persistMessages() [debounced]
               │ updateCurrentOutput()
               ▼
┌────────────────────────────────────────────┐
│  ThreadTimelineState (@Observable)         │
│  refreshThreadTimelineState()              │
│  → genera TurnTimelineRenderSnapshot       │
└──────────────┬─────────────────────────────┘
               │ SwiftUI observes changes
               ▼
┌────────────────────────────────────────────┐
│  TurnTimelineReducer.project()             │
│  → Ordena, deduplica, colapsa             │
│  → TurnTimelineProjection                  │
└──────────────┬─────────────────────────────┘
               │
               ▼
┌────────────────────────────────────────────┐
│  TurnTimelineView                          │
│  → LazyVStack + ScrollViewReader           │
│  → ForEach → MessageRow                    │
│     → userBubble / assistantView / system  │
│     → MarkdownTextView / TypingIndicator   │
│     → MessageRowRenderModelCache (LRU)     │
└────────────────────────────────────────────┘
```

---

## 12. Patrones Arquitectonicos Notables

1. **UI Optimista**: Los mensajes del usuario aparecen inmediatamente con `deliveryState: .pending`, se confirman o fallan despues. Esto da una sensacion de respuesta instantanea.

2. **Snapshot Isolation**: `ThreadTimelineState` genera `TurnTimelineRenderSnapshot` inmutables para que la vista nunca observe mutaciones parciales del estado.

3. **Tolerancia a formatos legacy**: El sistema soporta multiples convenciones de nombres de metodos y campos (camelCase, snake_case, variantes con/sin prefijo) con normalizacion agresiva. ~25 variantes de itemId, multiples metodos legacy `codex/event/*`.

4. **Cache de renderizado multi-nivel**: 9+ caches LRU thread-safe evitan reparsear markdown, diffs, thinking sections, etc. en cada scroll. Cada `MessageRow` usa `MessageRowRenderModel` cacheado.

5. **Persistencia con debounce**: Las escrituras a disco se agrupan durante streaming para no degradar la UI. Encriptacion AES-256-GCM con clave en Keychain.

6. **Order index monotonico**: En lugar de depender de timestamps, cada mensaje tiene un contador global atomico que garantiza orden estable. `CodexMessageOrderCounter` se seed desde disco al iniciar.

7. **Merge inteligente de historia**: Al cargar historial del servidor, se fusiona con mensajes locales protegiendo los que estan en streaming activo. Si hay un turno running, se salta el merge.

8. **Lazy placeholder creation**: Los placeholders de assistant message NO se crean en `turn/started` sino en el primer delta, para evitar que aparezcan antes de los thinking messages.

9. **Protected running fallback**: Antes de recibir el turnId, el thread se marca como running via `protectedRunningFallbackThreadIDs` para que la UI muestre el estado correcto inmediatamente.

10. **Request-response pairing**: Cada RPC request se empareja con su response via `CheckedContinuation` almacenada en `pendingRequests[idKey]`. Si la conexion se pierde, `failAllPendingRequests()` resume todas con error.

11. **Local-first design**: Relay session guardada en Keychain permite reconexion sin re-escanear QR. Estado local es fuente de verdad, sincronizado periodicamente con el servidor.

12. **Single responsibility via extensions**: `CodexService` se divide en 14+ extensions por responsabilidad (`+Transport`, `+Incoming`, `+Messages`, `+ThreadsTurns`, `+Sync`, `+Connection`, `+SecureTransport`, etc).
