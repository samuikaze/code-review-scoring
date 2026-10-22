# 注意事項

<!-- markdownlint-disable MD028 -->
<!-- markdownlint-disable MD033 -->

[English](../en/notices.md) | 繁體中文

- [評分標準](#評分標準)
- [GitHub Copilot 的適用性](#github-copilot-的適用性)

## 評分標準

- **標準文件的位置因人而異**：`configs/standards.ini` 不進版控，標準文件與掃描規則檔可以放在專案以外。換電腦或換人時，請各自複製 `configs/standards.example.ini` 並設定路徑；Windows 的路徑請使用斜線。
- **評分途中不要修改標準**：步驟 1 會把標準的內容與 sha256 存成快照，步驟 3～5 都以快照評分。標準文件、掃描規則檔或 `standards.ini` 的設定在評分途中被修改時，狀態腳本會拒絕繼續；請還原修改，或以 `review-state init --reset` 重新開始。
- **修改標準後先執行 lint**：評分流程不執行 lint，格式有誤時評分腳本只會停止並提示。修改後執行 `standard lint`，並以 `standard diff <舊版> <新版>` 確認實際改變的檢查項；lint 只能檢查格式，規則內容是否正確仍需人工審查。
- **掃描規則檔可能過期**：掃描規則檔檔頭記錄產生時依據的標準版本與雜湊值，標準修改後 lint 會警告過期，請重新產生或審核掃描規則。
- **同一個 PR 可能產出多份報告**：每套符合異動檔案的框架標準各一份，判斷不出歸屬的通用檔案（例如儲存庫根目錄的 README）會列在每一份報告中，落在這些檔案上的 CR 意見也會出現在每一份報告中。

## GitHub Copilot 的適用性

本節整理 PR 評分 Skill 在 GitHub Copilot 上的適用情況與已知限制，依據 2026 年 10 月查證的官方文件與 issue。Copilot 更新頻繁，使用前請再確認最新狀況。

### 總結

大致適用。Skill 的放置位置、主 Agent 派發 Sub-Agent、Sub-Agent 透過檔案提問等設計都和 Copilot 的行為相符。主要限制是 **Sub-Agent 的 reasoning 設定目前無法套用**，以及 **指定 model 時有費用等級限制**。

### 逐項說明

| 規則 | 是否適用 | 說明 |
| --- | --- | --- |
| Skill 放置位置與格式 | ✅ | Copilot 會讀取 `.github/skills`、`.claude/skills`、`.agents/skills`，VS Code、Copilot CLI 與雲端的 coding agent 都適用，SKILL.md 格式相同。 |
| 主 Agent 派發 Sub-Agent | ✅ | VS Code 用 `runSubagent`。Sub-Agent 預設不能再派發 Sub-Agent，和「只有主 Agent 派發」的設計相符。 |
| Sub-Agent 透過 `questions.md` 提問 | ✅ | Copilot 的 Sub-Agent 本來就不能向使用者提問，和這個設計一致。 |
| 指定 Sub-Agent 的 model | ⚠️ 有條件 | `runSubagent` 從 VS Code 1.117 起可帶 `model` 參數。但如果指定的 model 費用等級高於主對話的 model，Sub-Agent 不會執行。 |
| 指定 Sub-Agent 的 reasoning | ❌ 目前不行 | `runSubagent` 不能逐次指定 reasoning，只有自訂 agent 檔（`.agent.md`）的 `reasoning-effort` 能設定。VS Code 內建的本機執行方式會忽略這個值，相關 issue 仍未修正；Copilot CLI 會套用。 |
| Windows 執行腳本 | ✅ | VS Code 在 Windows 預設使用 PowerShell，`.ps1` 已處理 UTF-8。 |
| Copilot CLI | ⚠️ | 有 Sub-Agent 功能，但查不到能否逐次指定 model 或 reasoning。 |
| Copilot coding agent（雲端） | ⚠️ 不建議 | 以 PR 形式非同步執行，無法即時轉達 `pending` 的問題。 |

### 隱憂與因應方式

#### 1. `configs/settings.ini` 中 `[Copilot]` 的 reasoning 不會生效

- **影響**：設定會被記錄，但 Sub-Agent 實際上沿用主對話的 reasoning。
- **目前做法**：主 Agent 儲存設定時會告知使用者此值不會套用。
- **可行的改善**：讓主 Agent 依 `configs/settings.ini` 自動產生一個帶 `model` 與 `reasoning-effort` 的自訂 agent 檔，再用它派發 Sub-Agent。此方式在 Copilot CLI 有效，在 VS Code 本機執行方式仍會被忽略，因此尚未實作。

#### 2. Sub-Agent 的 model 不能高於主對話的費用等級

- **影響**：設定的 model 等級太高時，Sub-Agent 不會執行，步驟會停在「尚未開始」。
- **目前做法**：主 Agent 遇到 Sub-Agent 結束後步驟仍未開始時，會提示檢查費用等級並重派一次；再失敗就停止並告知使用者。
- **建議**：在 `[Copilot]` 設定不高於平常主對話所用等級的 model。

#### 3. Copilot CLI 可能無法指定 Sub-Agent 的 model 與 reasoning

- **影響**：Sub-Agent 可能使用預設值。
- **目前做法**：主 Agent 會告知使用者並改用平台預設值，流程照常進行。

#### 4. Copilot coding agent（雲端）不適合跑完整流程

- **影響**：無法即時向使用者轉達 `pending` 的問題，只有所有資料事先提供齊全時才跑得完。
- **另一個限制**：`.github/skills/` 已列在 `.gitignore`，而且 Windows 的 Junction 無法提交到 git。雲端環境要讀到 Skill，需要在雲端環境執行連結腳本，或從 `.gitignore` 移除 `.github/skills/` 後提交 symlink 或實體目錄。

#### 5. 尚未實際驗證的項目

- 尚未在 Copilot 上實際執行完整流程。
- 尚未確認 Copilot 是否會讀取透過 symlink 或 Junction 連進 `.github/skills` 的 Skill。若讀不到，請改為把實體目錄複製到 `.github/skills`。

### 參考資料

- [Use Agent Skills in VS Code](https://code.visualstudio.com/docs/agent-customization/agent-skills)
- [Adding agent skills for GitHub Copilot - GitHub Docs](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/add-skills)
- [GitHub Copilot Skills: Where to Put Skills - SmartScope](https://smartscope.blog/en/generative-ai/github-copilot/github-copilot-skills-guide/)
- [Subagents in VS Code](https://code.visualstudio.com/docs/copilot/agents/subagents)
- [Using subagents in your IDE - GitHub Docs](https://docs.github.com/en/copilot/how-tos/copilot-in-your-ide/use-copilot-agents/use-subagents?tool=vscode)
- [Allow sub-agents to be invoked with a different model · microsoft/vscode#310138](https://github.com/microsoft/vscode/issues/310138)
- [Local harness should honor reasoning-effort · microsoft/vscode#334592](https://github.com/microsoft/vscode/issues/334592)
- [Custom Agent YAML Frontmatter Should Support Reasoning Effort · github/copilot-cli#2904](https://github.com/github/copilot-cli/issues/2904)
- [Comparing GitHub Copilot CLI customization features - GitHub Docs](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/comparing-cli-features)
- [GitHub Copilot CLI changelog (2026-01-14)](https://github.blog/changelog/2026-01-14-github-copilot-cli-enhanced-agents-context-management-and-new-ways-to-install/)
