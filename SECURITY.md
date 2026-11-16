# 安全策略 · Security Policy

## 报告漏洞

如果你发现了安全问题——尤其是可能让 API Key 泄露的问题（例如 Key 被写进日志、文件、错误信息，或发给了用户配置之外的地址）——**请不要公开提 Issue**。

请通过 GitHub 的私密漏洞报告提交：仓库页面 → Security → Report a vulnerability。

报告里请写明受影响的版本或提交、复现步骤和影响范围。维护者会尽快确认并回复。

## Reporting a vulnerability

If you find a security issue, especially anything that could leak a user's API key, **please don't open a public issue**. Examples: the key ending up in logs, files or error messages, or being sent anywhere other than the service the user configured.

Report it privately through GitHub: repository page → Security → Report a vulnerability.

Please include the affected version or commit, steps to reproduce, and the impact. The maintainer will acknowledge and follow up as soon as possible.

## 设计上的安全承诺 · Security commitments by design

- API Key 只保存在 macOS 系统钥匙串，不落盘、不进日志。 / API keys live only in the macOS Keychain, never on disk or in logs.
- 翻译内容只发给用户配置的模型服务；App 没有自建服务器、不收集使用数据。 / Content goes only to the user-configured model service; there is no project server and no telemetry.
- 不申请辅助功能、屏幕录制、输入监控等系统权限。 / No Accessibility, Screen Recording or Input Monitoring permissions are requested.
