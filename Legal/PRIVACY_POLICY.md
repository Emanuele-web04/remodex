# Remodex — Data Protection Notice

**Last updated:** March 25, 2026

This Data Protection Notice explains how the Remodex mobile application ("App"), developed by Emanuele Di Pietro ("Developer", "we", "us", or "our"), handles your information. Remodex is designed to let you control a Codex runtime on your Mac from your iPhone. Most conversation and workspace activity is processed on your paired Mac, but the App Store version can also use developer-operated relay infrastructure to connect your devices.

---

## 1. Overview

Remodex is a local-first remote companion for Codex on your Mac. In practice, this means:

- Your conversations, repository actions, and workspace interactions are primarily processed on your paired Mac.
- We do not operate user accounts or cloud databases.
- We do not run analytics, advertising, or cross-app tracking.
- We do not sell your personal information.
- After the secure session is established, message contents sent between your iPhone and Mac are end-to-end encrypted.
- The App Store build may use a developer-operated hosted relay to help your iPhone reach your paired Mac.

## 2. Information We Collect

### 2.1 Information You Provide Through the App

- **Chat messages and prompts** — Your messages are sent from the iPhone to your paired Mac for processing. After the secure transport handshake is complete, the relay forwards encrypted payloads and cannot read message contents.
- **Photo attachments** — Images you attach from the camera or photo library are sent to your paired Mac over the secure channel.
- **Voice recordings** — When you use voice mode, the App records a temporary WAV file on your iPhone and uploads that audio directly from the iPhone to OpenAI/ChatGPT for transcription. The request is authenticated with a ChatGPT token resolved from your paired Mac over the encrypted Remodex channel.
- **Git operations** — Commands you initiate from the App, such as commit, pull, push, branch, or status actions, are executed on your paired Mac.

### 2.2 Information Collected Automatically

- **Pairing and identity keys** — The App generates cryptographic identity material used for secure pairing and trusted reconnect.
- **Relay and trusted-device metadata** — The App stores relay session data, trusted Mac identifiers, and reconnect metadata needed to restore a secure connection.
- **Subscription and purchase state** — We use RevenueCat and Apple to determine whether your Pro entitlement is active. This includes entitlement status and related purchase metadata exposed by those services to the app.
- **Connection metadata** — If you use a hosted relay, the relay can process network and session metadata needed to route traffic, maintain trusted reconnect, and operate the service.

### 2.3 Information We Do Not Collect for Analytics or Advertising

- We do **not** collect analytics, telemetry, advertising profiles, or behavioral tracking data.
- We do **not** use third-party advertising SDKs.
- We do **not** track you across other companies' apps or websites.
- We do **not** require your name, phone number, or email address to use the App.

If you contact us directly, we will of course receive whatever information you include in that message.

## 3. How We Use Information

We use the information above only to operate and secure Remodex, including:

- pairing your iPhone with your Mac
- routing encrypted traffic between your iPhone and Mac
- performing trusted reconnect
- checking and restoring subscription entitlements
- transcribing voice input when you explicitly use voice mode
- maintaining app security, stability, and abuse prevention for the hosted infrastructure

We do not use your information for advertising, profiling, or resale.

### 3.1 GDPR Legal Bases

If you are in the European Economic Area, we rely on the following legal bases:

- **Contract performance** — to provide the App's core features, including pairing, relay transport, voice transcription, and subscription handling
- **Legitimate interests** — to secure the service, prevent abuse, maintain relay connectivity, and protect users and infrastructure
- **Consent** — for permissions such as camera, microphone, photo library, and local network access

## 4. Services That Process Data

### 4.1 Developer-Operated Remodex Infrastructure

The App Store build can use developer-operated infrastructure for:

- **Hosted relay transport** — to route traffic between your iPhone and paired Mac when direct connectivity is not used
- **Trusted reconnect resolution** — to help your already-paired iPhone locate the current live session for your trusted Mac

This infrastructure may process:

- session identifiers and trusted-device metadata
- connection metadata such as IP address, timestamps, and route-level request data
- secure control messages needed to establish the encrypted session

Once the secure session is active, the hosted relay does **not** decrypt your Remodex application payloads.

### 4.2 OpenAI / ChatGPT

When you use voice mode, your audio recording is sent to OpenAI/ChatGPT for speech-to-text transcription.

This is the only instance where your data is processed by a third-party AI service.

- Privacy policy: [openai.com/privacy](https://openai.com/privacy)

### 4.3 RevenueCat

RevenueCat is used for subscription and entitlement management. RevenueCat may process an anonymous app user identifier, entitlement status, purchase information, device/app metadata, and subscription management URLs.

- Privacy policy: [www.revenuecat.com/privacy](https://www.revenuecat.com/privacy)

### 4.4 Apple

Apple provides:

- App Store billing and subscription management
- iOS permission and platform services used by the app

- Privacy policy: [apple.com/privacy](https://www.apple.com/privacy/)

## 5. Data Storage and Security

### 5.1 On Your iPhone

- **Keychain** — sensitive values such as identity keys, pairing state, relay credentials, and encryption keys
- **Encrypted message cache** — chat history is stored locally in encrypted form using a Keychain-backed key
- **UserDefaults** — non-sensitive preferences and interface settings
- **Temporary files** — voice recordings are stored temporarily during capture/transcription

### 5.2 On Your Mac

Your paired Mac runs the local bridge and Codex runtime. Chat handling, git operations, and workspace actions are performed there.

### 5.3 On Hosted Relay Infrastructure

When the hosted relay is used, the server side may keep limited operational state such as active session state and trusted reconnect metadata needed to route traffic and restore a secure connection.

### 5.4 In Transit

- The iPhone and Mac establish an end-to-end encrypted session using modern cryptography.
- The relay can observe connection metadata and secure-session setup traffic, but not encrypted application payloads after the secure session is established.
- Voice transcription and subscription requests are sent over HTTPS/TLS.

## 6. Data Retention

- **Chat history on iPhone** — stored locally until the app's local storage is removed. Unpairing or forgetting a Mac does **not** automatically erase local chat history.
- **Voice recordings** — temporary voice files are deleted by the app after transcription completes or fails.
- **Pairing and trusted-device state** — retained in local app storage and Keychain until removed by app actions or platform behavior.
- **Subscription records** — retained by Apple and RevenueCat according to their own policies.

We do not maintain a cloud chat history database for your message contents.

## 7. Your Choices

### 7.1 Permissions

You can revoke camera, microphone, photo library, and local network permissions at any time in iOS Settings. Doing so disables the related feature.

### 7.2 Subscription Management

You can manage or cancel your subscription through Apple account settings or through the in-app management link when available.

### 7.3 Local Data and Reset

- Deleting the app removes ordinary app-container files such as local encrypted chat history and temporary files.
- Keychain items are managed by iOS separately from ordinary app files and may persist differently, including across reinstall scenarios.
- If you want to reset pairing/trusted-device state before deleting or reinstalling the app, use the in-app forget/unpair controls first.

## 8. Privacy Rights

Depending on your jurisdiction, you may have rights to access, correct, delete, restrict, or object to the processing of personal information, and to request portability where applicable.

Because Remodex is primarily local-first, much of your data remains under your direct control on your devices. We do not maintain a centralized database of your personal data. Some data may be processed or retained by Apple, RevenueCat, and OpenAI according to their own operational needs and policies.

### 8.1 California Notice

We do not sell or share personal information for cross-context behavioral advertising.

## 9. Children's Privacy

The App is not directed to children under 13, or the minimum age required by local law. We do not knowingly collect personal information from children.

## 10. International Transfers

Depending on where you use the App and where service providers or hosted infrastructure are located, data processed by OpenAI, RevenueCat, Apple, or the hosted relay may be handled outside your country of residence.

## 11. Changes to This Policy

We may update this Data Protection Notice from time to time. When we do, we will update the "Last updated" date above.

## 12. Contact

If you have questions about this Data Protection Notice or want to exercise your privacy rights, you can reach us at:

- **Email:** emandipietro@gmail.com
- **GitHub:** [github.com/Emanuele-web04/remodex](https://github.com/Emanuele-web04/remodex)
- **X (Twitter):** [@emanueledpt](https://x.com/emanueledpt)
