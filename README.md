# Code Review Scoring

PR 的 Code Review 與程式碼品質評分框架，以 Agent Skills 實作，遵循 [Agent Skills](https://agentskills.io) 規格，可用於 Claude Code、GitHub Copilot、Codex 等支援 Skill 的工具。

- **評分**：依 `configs/standards.ini` 登錄的評分標準文件評分，不綁定任何技術。每套框架標準（例如 Spring Boot 3、Angular）各產出一份報告，不屬於任何框架的檔案（README、CI 設定、Dockerfile 等）以通用標準評分。標準文件以 Markdown 撰寫，可以放在專案以外，見「評分標準」。
- **CR**：其他技術（例如前端）或其他團隊的 CR 規範，以外掛 Skill 的方式掛進流程，不受技術限制。
- **報告**：CR 結果與評分結果合併成一份報告。

## 評分流程

依「閱讀規格書 → CR → 分析程式碼 → 打分數 → 產出報告」五個步驟執行，另有一個主流程 Skill 負責控管。步驟 2 的 CR 由 `configs/plugins.ini` 登記的外掛 Skill 執行；步驟 3 分析程式碼時會確認 CR 意見，符合評分檢查項的轉為扣分項，所以分數同時反映評分規則與 CR 結果。最終報告包含 CR 結果與分數結果：

| Skill | 角色 | 產出（本專案根目錄的 `tmp/` 下；最終報告在本專案的 `reports/`） |
| --- | --- | --- |
| `code-review-scoring` | 主 Agent：確認執行方式、依序派發 Sub-Agent、轉達問題、以狀態檔把關 | `request.md`、`inputs/`、`answers.md` |
| `code-review-scoring-spec-reading` | 步驟 1：閱讀規格書，並規劃這個 PR 要用哪些評分標準 | `step1/pr.diff`、`step1/spec-context.md`、`step1/standards/` |
| 外掛 CR Skill（`configs/plugins.ini`） | 步驟 2：CR，依異動檔案決定要跑哪些外掛 | `step2/plan.tsv`、`step2/<外掛>/cr.txt` |
| `code-review-scoring-code-analysis` | 步驟 3：分析程式碼（確認 CR 意見並轉為扣分項），每個評分標準各做一次 | `step3/<標準>/prepared.txt`、`step3/<標準>/findings.txt` |
| `code-review-scoring-score` | 步驟 4：打分數（完整流程中由 `review-state finish` 直接執行腳本） | `step4/<標準>/score.tsv`、`step4/<標準>/score.json` |
| `code-review-scoring-report` | 步驟 5：產出報告（CR 結果＋分數結果；完整流程中由 `review-state finish` 直接執行腳本） | 最終報告 `reports/<日期>_<PR 標題>_<標準>.md`，工作副本 `step5/<標準>/report.md` |

### 依評分標準拆分報告

一個 PR 可能同時改到後端與前端。步驟 1 會依 `configs/standards.ini` 規劃這次的評分（`standard plan`）：

- 每個框架評分標準（例如 `springboot-3`、`angular`）只要有檔案符合它的 `applies`，就各自產出一份報告；步驟 3～5 依標準分開執行，狀態也分開記錄。
- 不屬於任何框架標準的檔案（README、CI 設定、Dockerfile 等）用通用標準評分，歸入同一個專案的報告：以檔案所在目錄往上找，最近的目錄中有哪個框架標準的檔案，就歸入那份報告；判斷不出來時（例如根目錄的 README）每份報告都會列入。
- PR 完全沒有框架標準的檔案時，只用通用標準產出一份報告，所以每個 PR 至少有一份報告。
- 每份報告只列出落在自己檔案上的 CR 意見；意見編號維持外掛原本的編號，方便對照。
- 各標準的「事先確認事項」會列在 `spec-context.md` 的嚴重度事實中，於步驟 1 與缺少的文件一起詢問。
- 步驟 1 會把每個標準解析後的內容存成快照（`step1/standards/<標準>.resolve`），並把標準名稱、版本與 sha256 記在 `request.md`。之後步驟 3～5 都以這份快照評分；若評分途中標準文件、掃描規則或 `standards.ini` 的設定被修改，狀態腳本會拒絕繼續，請還原修改，或以 `init --reset` 重新開始評分。

### 執行方式

主 Agent 在開始前會先詢問使用者：

- **完整流程**：依序執行五個步驟，前一步成功後才能進行下一步，不可跳步。是否派發 Sub-Agent 由 `configs/settings.ini` 的 `[workflow]` `subagent` 決定：`true` 時由主 Agent 為步驟 1～3 與每個 CR 外掛各派發一個 Sub-Agent；`false` 時由主 Agent 自己逐步執行，使用相同的指令、狀態檔與目錄。平台不支援 Sub-Agent 時，即使設為 `true` 也會由主 Agent 逐步執行。步驟 4、5 只需要執行腳本，一律由主 Agent 以 `review-state finish` 直接完成，不派發 Sub-Agent。
- **單一步驟**：直接在對話中執行某一個步驟 Skill，不使用狀態檔。

主 Agent 每次只要執行 `review-state next`，腳本就會印出下一個動作：要執行的步驟 prompt、要轉達的問題、失敗原因、`finish`，或最後的結果摘要。完成後主 Agent 只回覆等級、總分、各面向分數與報告路徑，不會把報告全文貼回對話，完整內容請看 `reports/` 中的檔案。

所有需要交接的內容都寫在 `tmp/`：你在對話中貼上的文件會存成 `tmp/inputs/` 中的檔案，各步驟在提問前會先把目前的成果存檔（例如步驟 3 的 `findings.draft.txt`），回覆後只套用答案，不會整步重做。評分中斷時，在新對話說「繼續評分」即可從 `tmp/` 接續。

### 設定檢查（完整流程每次執行前）

選擇完整流程後，主 Agent 的第一件事就是執行 `setup check`，確認專案根目錄的兩個設定檔。單一步驟用不到這兩個檔案，不會檢查。

| 設定檔 | 何時需要 | 缺少時 |
| --- | --- | --- |
| `configs/plugins.ini` | 每次執行完整流程都需要 | 要登記哪些 CR 外掛；不使用外掛時也要建立一份沒有外掛的檔案，表示已確認不用 |
| `configs/settings.ini` 的 `[workflow]` 區段 | 每次執行完整流程都需要 | `subagent=true`（每一步派發 Sub-Agent）或 `subagent=false`（主 Agent 逐步執行） |
| `configs/settings.ini` 中該平台的區段 | 只有 `subagent=true` 且平台支援 Sub-Agent 時 | Sub-Agent 要使用的 model 與 reasoning |

有缺少時，主 Agent 會告訴你缺了什麼，並詢問要用哪種方式建立：

- **腳本逐步詢問**：由你自己在終端機執行 `check` 印出的 `wizard` 指令，腳本會逐一詢問外掛名稱、路徑、適用範圍、模式，是否使用 Sub-Agent，以及 model 與 reasoning，並在登記時驗證外掛（SKILL.md 是否存在、名稱是否一致）。AI 無法代為執行，因為它需要互動式終端機；在 Claude Code 中可以輸入 `! <指令>` 直接在對話中執行。
- **AI 詢問**：主 Agent 在一則訊息中問完所需資料，再以 `setup plugin`、`setup plugins --none`、`review-state config --subagent`、`review-state config --platform` 寫入設定檔。外掛驗證不通過時會告訴你原因並重新詢問。

設定檔已從專案根目錄搬到 `configs/`：`configs.ini` 改名為 `configs/settings.ini`，`plugins.ini` 搬到 `configs/plugins.ini`。專案根目錄還留有舊的 `configs.ini`、`plugins.ini` 時，`check` 與 `link-skills` 會停下並印出搬移指令，請自行搬移後再執行；`plugins.ini` 中的相對路徑要在前面加上 `../`。

`check` 通過時會印出 `execution:` 一行，說明這次以 Sub-Agent 或由主 Agent 逐步執行。登記了外掛之後，主 Agent 會執行 `link-skills` 連結外掛 Skill，接著再次執行 `check`，通過後才會繼續。`review-state init` 也會在 `configs/plugins.ini` 不存在時拒絕執行，所以不會因為忘了建立清單而靜靜略過 CR。

也可以不透過 AI，直接在專案中執行：

```bash
bash skills/code-review-scoring/scripts/setup.sh check --platform Claude
bash skills/code-review-scoring/scripts/setup.sh wizard --platform Claude
```

```powershell
powershell -ExecutionPolicy Bypass -File skills\code-review-scoring\scripts\setup.ps1 wizard --platform Claude
```

### 狀態控管

暫存檔與報告一律寫在本專案根目錄的 `tmp/`、`reports/`，不會寫進被審查的專案。腳本以 Skill 實體資料夾往上兩層找到本專案根目錄（經由 `link-skills` 建立的連結執行也一樣），`--root` 可改用其他目錄，報告則發佈到該目錄旁的 `reports/`。git 指令仍在被審查的專案執行：主 Agent 在被審查專案的根目錄執行 `init`，或以 `--repo` 指定。

```text
tmp/
  .gitkeep             保留目錄用
  .gitignore           只有 git 尚未忽略 tmp/ 時才自動產生（* 與 !.gitkeep）
  request.md           主 Agent 記錄 PR、diff 範圍與使用者提供的文件
  inputs/              使用者在對話中貼上的文件，由主 Agent 存成檔案（--reset 時一併清除）
  stepN-working        Sub-Agent 開始執行
  stepN-pending        Sub-Agent 需要使用者回覆，問題寫在 stepN/questions.md
  stepN-success        步驟完成
  stepN-failed         步驟失敗，原因寫在狀態檔內
  step2-<外掛>-<狀態>   步驟 2 中每個 CR 外掛各自的狀態檔
  stepN-<標準>-<狀態>   步驟 3～5 中每個評分標準各自的狀態檔
  step1/ … step5/      各步驟產出；questions.md（步驟提出的問題）、answers.md（使用者回覆）、errors.log（失敗紀錄）
  step1/standards/     評分規劃：plan.tsv（報告與檔案的歸屬）、<標準>.diff（該報告的 diff）、<標準>.resolve（標準快照）、confirm.tsv（事先確認事項）
  step2/<外掛>/        files.txt 與 diff.patch（要審查的範圍）、raw/（外掛原始輸出）、cr.txt（整理後的 CR 結果）
  step3/<標準>/ … step5/<標準>/  步驟 3～5 依評分標準分開的產出
  step3/<標準>/findings.draft.txt  步驟 3 提問前先存下的扣分項草稿，回覆後從這裡接續
reports/
  <日期>_<PR 標題>_<標準>.md   最終報告（CR 結果＋分數結果），每個評分標準一份，步驟 5 成功前必須已發佈到這裡
```

- 狀態檔由 Sub-Agent 透過 `review-state` 腳本產生；檔案不存在代表該步驟尚未開始。
- 腳本會強制把關：前一步不是 `success` 時不能開始下一步；必要產出不存在或已過期時不能標記 `success`；重跑某一步時，後續步驟的狀態會被清除。步驟 3 標記 `success` 時會以 `score --check` 驗證 `findings.txt`，格式或位置有誤會當場退回，不必等到步驟 4 才失敗、再整步重做步驟 3。
- Sub-Agent 無法直接和使用者對話。需要詢問時先把目前成果存檔，再寫入 `stepN/questions.md` 並標記 `pending`；主 Agent 詢問使用者、把回覆寫入 `stepN/answers.md` 後，再重新執行同一步，該步驟會從存檔接續。
- 評分標準的「事先確認事項」（例如是否跨時區、資料表是否持續成長）會在步驟 1 與缺少的文件一起詢問，減少步驟 3 再停下來提問的機會。
- 步驟失敗時，詳細錯誤寫入該步驟目錄的 `errors.log`（例如 `tmp/step4/springboot-3/errors.log`），狀態腳本標記 `failed` 時也會追加一行摘要。
- 評分標準在步驟 1 規劃之後被修改時，步驟 3～5 的狀態變更與 `finish` 都會被拒絕（結束碼 5），避免同一份報告混用新舊規則。
- 支援的 Sub-Agent 工具：Claude Code 的 Agent 工具、GitHub Copilot（VS Code agent mode）的 `runSubagent`，或其他平台的同等工具。

### 執行方式與 Sub-Agent 設定

設定存在專案根目錄的 `configs/settings.ini`（與外掛清單 `configs/plugins.ini` 放在同一個目錄），由設定檢查在第一次需要時要求建立（見上方「設定檢查」），之後直接沿用：

- `[workflow]` 的 `subagent`：`true` 時每一步派發一個 Sub-Agent，`false` 時只由主 Agent 逐步執行。設為 `false` 時不需要平台區段。
- 各平台一個區段（`workflow` 保留給上述設定，不能當平台名稱）：Sub-Agent 要使用的 model 與 reasoning，在某個平台第一次以 Sub-Agent 執行時建立。

```ini
[workflow]
subagent="true"

[Claude]
model="sonnet 5.5"
reasoning="high"

[Codex]
model="gpt-5.6"
reasoning="xhigh"
```

要修改時可直接編輯此檔，或執行 `review-state config --subagent true|false`、`review-state config --platform <名稱> --model "<model>" --reasoning "<level>"`。也可以在第一次使用前，從範本 `configs/settings.example.ini` 複製一份 `configs/settings.ini`，取消註解要用的區段後修改。

> [!WARNING]
> **GitHub Copilot 的已知限制**
>
> - `[Copilot]` 的 reasoning 設定目前不會套用到 Sub-Agent：`runSubagent` 無法逐次指定 reasoning，VS Code 的本機執行方式也會忽略自訂 agent 檔的 `reasoning-effort`。
> - Sub-Agent 指定的 model 不能高於主對話 model 的費用等級，否則 Sub-Agent 不會執行。
> - Copilot CLI 可能無法指定 Sub-Agent 的 model 與 reasoning；雲端的 Copilot coding agent 無法即時轉達待確認問題，不適合跑完整流程。
> - 尚未在 Copilot 上實際驗證完整流程，也尚未確認 Copilot 是否會讀取以 symlink 或 Junction 連結的 Skill。
>
> 詳細說明與因應方式請見 [docs/notices.md](docs/notices.md)。

## 目錄結構

```text
skills/
  code-review-scoring/
    SKILL.md
    assets/request-template.md
    assets/prompts/step1.md … step3.md   # 步驟 1～3 的指令模板（step2.md 為 CR 外掛用）
    assets/prompts/protocol.md            # 各步驟共用的狀態協定（[sub] / [inline] 開頭的行只用於對應的執行方式）
    references/setup.md                   # 設定檢查、平台設定、狀態指令與目錄說明（需要時才載入）
    scripts/review-state.{sh,zsh,ps1}     # init / next / finish / show / cr-plan / prompt / set / config（--help 列出用法）
    scripts/setup.{sh,zsh,ps1}            # 設定檢查與建立 configs/plugins.ini、configs/settings.ini（check / wizard / plugins / plugin）
    scripts/standard.{sh,zsh,ps1}         # 評分標準的 lint / parse / diff / resolve / plan / stamp（lint、stamp 只在維護標準時執行，plan 供步驟 1 規劃評分）
    scripts/lib/standard.{awk,ps1}        # 評分標準的解析器（awk 供 bash、zsh 共用，PowerShell 版規則與訊息相同）
  code-review-scoring-spec-reading/
    SKILL.md
    assets/spec-context-template.md
    scripts/init-workspace.{sh,zsh,ps1}   # 儲存 diff、建立 spec-context.md
    scripts/check-context.{sh,zsh,ps1}    # 輸入資料、待確認問題與評分標準的事先確認事項是否都已處理
  code-review-scoring-code-analysis/
    SKILL.md
    references/upstream.md                # 上游因素判斷（懷疑上游因素時才載入）
    references/findings-format.md         # findings.txt 格式
    scripts/prepare-diff.{sh,zsh,ps1}     # 掃描規則讀自 configs/standards.ini 登錄的掃描規則檔（scan）
  code-review-scoring-score/
    SKILL.md
    scripts/score.{sh,zsh,ps1}            # 檢查項與嚴重度讀自 configs/standards.ini 登錄的評分標準
  code-review-scoring-report/
    SKILL.md
    assets/report-template.md             # 分數報告模板（可自行調整）
    assets/labels.tsv                     # 報告中由腳本插入的文字
    references/placeholders.md            # 模板佔位符號說明
  code-review-scoring-standard/           # 維護評分標準用（不參與評分流程）
    SKILL.md                              # 檢查、產生、審核三種模式
    references/scan-format.md             # 掃描規則檔格式與正規表示式限制
    references/review-checklist.md        # 審核掃描規則的檢查清單與 review.md 格式
    assets/generator-prompt.md            # 產生掃描規則的 Sub-Agent 指令
scripts/
  link-skills.{sh,zsh,ps1}                # 依 skills/ 與 configs/plugins.ini 同步各工具讀取 Skill 的目錄
configs/                                  # 設定檔（只有 *.example.ini 進版控）
  settings.example.ini                    # 執行方式、Sub-Agent 的 model 與 reasoning、評分配分的範本（settings.ini 首次使用時自動產生）
  plugins.example.ini                     # 外掛 Skill 清單範本（複製為 plugins.ini 使用）
  standards.example.ini                   # 評分標準清單範本（複製為 standards.ini 使用）
docs/
  notices.md                              # 注意事項（評分標準、GitHub Copilot 適用性）
  templates/scoring-rule-template.md      # 評分標準文件的模板
tests/
  standards/                              # 評分標準 lint 的測試案例；compare.sh 比對三種 shell 的輸出與 expected.txt
  score/                                  # score 的測試案例（legacy.md 的檢查項與舊 rules.tsv 相同，確保分數不變）
  prepare/                                # prepare-diff 的測試案例（legacy.tsv 為舊 scan-rules.tsv 的規則，另含通用標準的掃描規則）
  plan/                                   # standard plan 的測試案例（兩套框架標準與通用標準、各層目錄的通用檔案）
  workflow/                               # 完整流程的端對端測試（暫存 git 儲存庫、兩份報告、CR 意見分流、標準被修改時拒絕繼續）
tmp/                                      # 評分過程的暫存檔（所有腳本的預設 review root，不進版控）
reports/                                  # 最終版分數報告（tmp/ 旁的 reports/，不進版控）
.gitattributes                            # 固定腳本與設定檔的換行格式
.gitignore
```

### 版控排除項目

`.gitignore` 排除以下內容（`tmp/`、`reports/` 只保留 `.gitkeep`）：

- `tmp/*`、`reports/*`：評分過程與報告，含 PR 內容，不進版控。
- `.agents/`、`.github/skills/`、`.claude/skills/`：`link-skills` 產生的連結與 `.managed` 清單，各環境自行執行腳本建立。
- `configs/settings.ini`、`configs/plugins.ini`：各使用者自己的執行方式與 Sub-Agent 設定、外掛清單（外掛路徑依各人環境而不同）。`.gitignore` 以 `/configs/*.ini` 排除，版控中只放 `configs/*.example.ini` 範本；若團隊要共用同一份設定，請在 `.gitignore` 加上例外，例如 `!/configs/plugins.ini`。
- `.DS_Store`、`Thumbs.db`、`desktop.ini`：作業系統產生的檔案。

### 換行格式

`.gitattributes` 固定 `.sh`、`.zsh`、`.awk`、`.tsv`、`.ini`、`.md` 使用 LF。Windows 上若設定了 `core.autocrlf=true`，沒有這個設定時取出的檔案會變成 CRLF，bash／zsh 腳本在 WSL、macOS、Linux 上會無法執行，awk 讀取規則表也會出錯。`.ps1` 則交由 git 依平台處理。

已經取出的工作目錄若是在加入 `.gitattributes` 之前建立的，請執行一次以下指令，讓 git 依新規則重新整理換行：

```bash
git add --renormalize .
```

每個 Skill 的 `scripts/lib/` 放 awk 核心（bash/zsh 共用）與 PowerShell 共用函式。為了讓每個 Skill 都能單獨安裝，`lib/common.ps1` 在各 Skill 中各有一份相同的副本，修改時請一併更新。

## 評分標準

評分標準是一份 Markdown 文件，評分流程中的 AI 與腳本讀取同一份文件：

- 依 `docs/templates/scoring-rule-template.md` 撰寫。「面向」「檢查項」「事先確認事項」三個章節由腳本解析，格式固定；「特例規則」「判斷提示」只給 AI 參考，可以自由撰寫。
- 在專案根目錄複製 `configs/standards.example.ini` 為 `configs/standards.ini`，每套標準一個區段，設定標準文件路徑（`path`）、適用的檔案（`applies`，框架標準必填）、掃描規則檔（`scan`，選填）與配分覆寫（`points.A`～`points.G`，選填）；通用標準設定 `role="common"`，檢查代碼以 `CM-` 開頭。各欄位的說明見範本中的註解。
- 標準文件與掃描規則檔可以放在專案以外，例如團隊共用的文件庫；路徑依各人環境而不同，所以 `standards.ini` 不進版控，換電腦或換人時請各自設定。
- 寫好或修改標準後，執行 `standard lint` 檢查格式、`applies` 是否重疊、配分加總與掃描規則：

  ```bash
  bash skills/code-review-scoring/scripts/standard.sh lint
  ```

  ```powershell
  powershell -ExecutionPolicy Bypass -File skills\code-review-scoring\scripts\standard.ps1 lint
  ```

- 評分流程不執行 lint。標準格式有誤時，評分腳本會停止並提示先執行 lint。
- 掃描規則檔（TSV）列出可以用正規表示式找出的候選線索，只是提示，不會直接扣分；格式與 `@scope`、`@pr` 記錄見範本與 `tests/prepare/` 的例子。
- 評分途中不要修改標準：步驟 1 會記錄當下的標準，之後被修改時流程會拒絕繼續（見「依評分標準拆分報告」）。

### 維護評分標準

`code-review-scoring-standard` Skill 只在你提到維護標準時觸發（例如「檢查評分標準」「產生掃描規則」「審核掃描規則」），評分流程不會載入它：

- **檢查模式**：對標準文件與掃描規則檔執行 lint，說明錯誤與警告的修正方式，不修改任何檔案。
- **產生模式**：依標準文件產生或更新掃描規則檔，不需手寫正規表示式。
  1. 標準文件先通過 lint。
  2. 由一個 Sub-Agent 產生草稿 `tmp/scan-rules/<標準>/draft.tsv`，並在 `notes.md` 列出沒有產生規則的檢查項與原因。
  3. 腳本 lint 草稿（格式、引用的代碼與範圍、正規表示式在 awk 與 .NET 都能編譯）。
  4. 主 Agent 依固定的檢查清單審核草稿與標準文件是否有出入，結果寫到 `review.md`；有問題就退回 Sub-Agent 修正，最多 3 輪。
  5. 通過後列出和既有檔案的差異請你確認，確認後才以 `standard stamp` 寫入 `standards.ini` 的 `scan` 指定的位置，並在檔頭記錄來源標準文件的版本與雜湊值。
- **審核模式**：只對既有的掃描規則檔執行 lint 與審核，結果寫到 `review.md`，不修改任何檔案。

不支援 Sub-Agent 的平台（或 `subagent=false`）由主 Agent 依序完成產生與審核，流程與檔案相同，但獨立性較低。標準文件與 `standards.ini` 一律由你自己修改，AI 只回報問題。

## 調整配分

各面向滿分、各嚴重度扣分與等級門檻設定在專案根目錄 `configs/settings.ini` 的 `[points]`、`[deductions]`、`[grades]` 區段，未設定的項目使用預設值：

| 面向 | 預設滿分 | | 嚴重度 | 預設扣分 | | 等級 | 預設最低總分 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A 正確性 | 25 | | Critical | 10 | | S | 95 |
| B 安全性 | 15 | | Major | 5 | | A | 85 |
| C 測試品質 | 15 | | Minor | 2 | | B | 70 |
| D 架構與設計 | 15 | | Nit | 1 | | C | 55 |
| E 效能與資源 | 10 | | | | | D | 低於 C |
| F 可讀性 | 10 | | | | | | |
| G 可維護性 | 10 | | | | | | |

```ini
[points]
A="30"
B="20"
C="10"
D="10"
E="10"
F="10"
G="10"

[deductions]
Major="6"
merge="true"
```

- 七個面向合計必須為 100，等級門檻必須 S > A > B > C，數值為整數；不符合時打分數步驟會失敗並列出錯誤。
- 個別評分標準可以在 `configs/standards.ini` 用 `points.A`～`points.G` 覆寫面向滿分，覆寫值優先於 `[points]`，套用後合計同樣必須為 100（`standard lint` 會檢查）。
- 所有問題都會扣分，包括 Nit。對應不到 A～G 檢查項的問題（檢查代碼 `-`）與上游因素，依嚴重度直接從總分扣分，不計入任何面向；總分最低為 0。
- 有 Critical 扣分項時，等級上限固定為 B。
- 是否合併扣分由 `[deductions]` 的 `merge` 決定：
  - `merge="false"`（預設）：不合併，每一處問題各自是一筆扣分項，同一個檢查代碼出現在三處就扣三次。
  - `merge="true"`：合併，同一個檢查代碼只寫一筆並列出所有位置，只扣一次。
  - 分析程式碼步驟會從 `prepared.txt` 摘要的 `- deductions:` 一行得知目前的方式；面向得分最低為 0。
- 修改後重新執行打分數（步驟 4）與產出報告（步驟 5）即可生效（完整流程中執行 `review-state finish`）；範例見 `configs/settings.example.ini`。第一次建立的 `configs/settings.ini` 會從範本複製，配分區段預設為註解。

## 調整報告

- 版面與文字：編輯 `skills/code-review-scoring-report/assets/report-template.md`，可自由調整 CR 結果與評分結果兩部分的順序與標題。
- 腳本插入的用語（面向名稱、欄位名稱、上游因素類別、CR 表頭、「無」等）：編輯 `assets/labels.tsv`。
- 可用的佔位符號見 `references/placeholders.md`。

## 安裝到各工具

`configs/plugins.ini` 不需要事先手動建立：第一次執行完整流程時，設定檢查會引導建立（見「設定檢查」）。也可以先執行 `setup wizard`，或從範本 `configs/plugins.example.ini` 複製後自行編輯。

`link-skills` 會依 `skills/` 與 `configs/plugins.ini` 同步各工具讀取 Skill 的目錄：建立缺少的連結，並解除已從清單移除的外掛連結。重複執行是安全的；已是最新狀態時不會做任何變更。

```bash
# macOS / Linux（建立 symlink）
bash scripts/link-skills.sh                # 預設：.agents/skills 與 .github/skills
zsh  scripts/link-skills.zsh -t all        # 另外加上 .claude/skills
bash scripts/link-skills.sh --check        # 只檢查並列出會做的變更
```

```powershell
# Windows（建立 Junction，不需系統管理員權限）
powershell -ExecutionPolicy Bypass -File scripts\link-skills.ps1
powershell -ExecutionPolicy Bypass -File scripts\link-skills.ps1 -Target all
powershell -ExecutionPolicy Bypass -File scripts\link-skills.ps1 -Check
```

| 目標 | 目錄 | 使用的工具 |
| --- | --- | --- |
| `agents` | `.agents/skills` | Codex、Gemini CLI 等通用位置 |
| `github` | `.github/skills` | GitHub Copilot |
| `claude` | `.claude/skills` | Claude Code |

其他選項：`--config <檔案>`（PowerShell 為 `-Config`）改用其他外掛清單；`--remove`（`-Remove`）移除本腳本建立的所有連結，不會刪除 Skill 本身。

**請在開啟 AI 工具的對話之前執行同步。** 多數平台在對話開始時掃描 Skill，對話中途才建立的連結，那一輪可能讀不到。可以手動執行，或掛在 git hook（例如 `post-checkout`、`post-merge`）、VS Code 開啟資料夾時自動執行的工作。

注意：連結目錄已列在 `.gitignore`，不會進版控。若需要讓 GitHub Copilot coding agent 等雲端環境讀到 Skill，請在雲端環境中執行連結腳本；或從 `.gitignore` 移除 `.github/skills/`，在 macOS / Linux 建立 symlink 後提交（Windows Junction 無法被 git 追蹤）。

## 外掛 Skill

其他團隊或同仁已做好的 Skill（例如前端、後端的 CR Skill），不需要複製或改寫，在專案根目錄的 `configs/plugins.ini`（從 `configs/plugins.example.ini` 複製而來）登記路徑後執行 `link-skills` 即可掛進來：

```ini
[backend-code-review]
path="../../shared-skills/backend-code-review"
applies="*.java,*.kt,*.sql"
mode="mapped"

[frontend-code-review]
path="../../shared-skills/frontend-code-review"
applies="*.ts,*.tsx,*.vue,*.scss"
mode="advisory"
```

| 設定 | 必填 | 說明 |
| --- | --- | --- |
| 區段名稱 | 是 | 必須和該 Skill 的 SKILL.md 中的 `name` 一致 |
| `path` | 是 | Skill 資料夾路徑；相對路徑以 `configs/plugins.ini` 所在目錄（`configs/`）為準 |
| `applies` | 否 | 適用的檔案範圍（以逗號分隔的萬用字元）；未填表示全部異動檔案 |
| `mode` | 否 | `mapped`（預設）：步驟 3 確認 CR 意見，確認屬實的一律扣分，不成立的需說明原因；`advisory`：CR 意見只呈現在報告中，不影響分數 |

CR 外掛設為 `mapped` 時，對應不到評分標準檢查項的意見會歸入「其他」，依外掛給的嚴重度從總分扣分；外掛審查的技術沒有對應的評分標準，或不希望外掛影響分數時，請設為 `advisory`。每份報告只列出落在該標準檔案上的意見。

### 同步規則

- 只會變更本腳本建立過的連結，清單記錄在各目錄的 `.managed`。其他人或其他工具建立的連結、實體目錄一律不動。
- 從 `configs/plugins.ini` 移除的外掛，下次同步時會解除連結。
- 舊版腳本建立、指向相同位置的連結，會自動納入管理。
- 同步前會先檢查以下項目，任何一項不通過就不做任何變更並列出原因：
  - SKILL.md 是否存在；
  - 資料夾名稱、外掛區段名稱是否和 SKILL.md 的 `name` 一致；
  - 名稱是否和其他 Skill 重複；
  - 是否設定了 `disable-model-invocation: true`（設定後 Sub-Agent 無法透過 Skill 工具載入）；
  - 目標位置是否已有不是本腳本建立的同名連結或目錄。

### 載入方式與注意事項

- 流程中的每一步都由主 Agent 明確指定要用哪個 Skill，不靠 Agent 自行挑選，所以不需要限制 Agent 能讀哪些 Skill。
- Sub-Agent 會先用平台的 Skill 工具依名稱載入；如果平台的 Sub-Agent 沒有 Skill 工具，或找不到該 Skill，就直接讀取 `SKILL.md` 並照著執行。Claude Code 的 Sub-Agent 確定可以透過 Skill 工具載入；GitHub Copilot 官方文件未說明，因此保留這個備援。
- 外掛 Skill 的描述請寫得具體（例如註明「前端 Vue／TypeScript 的 CR 規範」）。描述太籠統時，使用者在主對話中說「審查這個 PR」，可能會和主流程 Skill 搶著被觸發。
- 外掛 Skill 不需要配合這套框架修改。主流程派給它的指令會限定審查範圍、輸出位置與狀態協定，並要求把結果整理成統一的 `cr.txt`。

### 外掛在流程中的執行方式（步驟 2）

1. 步驟 1 成功後，執行 `review-state cr-plan`：依 PR 實際異動的檔案（排除建置產物、自動產生檔與 lock 檔）比對每個外掛的 `applies`，決定要執行哪些外掛。各外掛要審查的檔案寫在 `tmp/step2/<外掛>/files.txt`，並切出只含這些檔案的 `diff.patch`。沒有任何外掛適用時，步驟 2 直接視為完成。
2. 每個適用的外掛由一個 Sub-Agent 依序執行（不支援 Sub-Agent 的平台由主 Agent 自己執行），一樣遵守狀態協定，狀態檔為 `tmp/step2-<外掛>-<狀態>`。`review-state next` 在步驟 2 尚未規劃時會自動執行 `cr-plan`。
3. 外掛只讀自己的 `diff.patch`，依自己的規範審查，原始輸出放在 `tmp/step2/<外掛>/raw/`，再整理成統一格式的 `cr.txt`：

   ```text
   S|整體結論
   C|Major|src/web/order/OrderForm.vue:42|FE-STATE-03
   problem: 表單送出後沒有處理 API 錯誤。
   suggestion: 在 catch 中顯示錯誤訊息。
   spec: docs/spec/order-sd.md:42,docs/spec/order-sd.md:57
   H|做得好的地方
   ```

   嚴重度依意義對應到 Critical、Major、Minor、Nit；外掛原本的規則編號放在第 4 欄；`spec:`（選填）列出意見依據的所有規格書位置。標記成功時，狀態腳本會驗證 `cr.txt` 的格式。
4. 所有外掛都成功後才能進入步驟 3。

### CR 結果如何影響分數（步驟 3）

- `prepare-diff` 會在 `prepared.txt` 列出每則意見的編號 `<外掛>#<序號>`（該外掛 `cr.txt` 中第幾則意見）。
- `mapped` 外掛的每一則意見，分析程式碼時都會對照程式碼確認，結果只有兩種：
  - **確認屬實**：一律扣分，並以 `source: <意見編號>` 註明來自哪則意見。符合 A～G 檢查項的，依評分規則的預設嚴重度與調整條件扣在該檢查項；對應不到任何檢查項的，檢查代碼寫 `-`，依外掛給的嚴重度從總分扣分；判斷根本原因疑似在上游的，記為上游因素並扣分。
  - **不成立**（外掛誤判、不在本次異動範圍內、無法在程式碼中確認）：寫成 `X|<意見編號>|原因`，原因會顯示在報告中。
- 打分數時會檢查每則 `mapped` 意見都已扣分或註明不成立，有遺漏就無法通過。
- `advisory` 外掛的意見只作為參考，不會轉為扣分項。

### 為什麼 CR 排在分析程式碼之前

- **分數更準確**：評分同時參考評分規則與 CR 規範，CR 找到的問題會反映在分數中。
- **節省 token**：每個外掛只讀自己範圍內的 `diff.patch`，不讀整份 PR；分析程式碼時把 CR 已找到的問題當成線索確認即可，不必重新從頭找一遍。

### 報告內容

最終報告分成兩部分：

- **一、CR 結果**：各外掛的總覽表（審查檔案數、各嚴重度意見數、結論）、各外掛的意見明細（依嚴重度排序）與亮點，以及因沒有符合的異動檔案而未執行的外掛。每則意見的標頭為「嚴重度 | 規則 | 判定」，程式碼位置與規格書位置逐行全部列出：

  ```text
  1. [Critical | EXT-CODE | A8]
     - 問題：取消訂單流程與規格不符。
     - 建議：依規格補上狀態檢查。
     - 程式碼位置：
       - `src/main/java/com/ex/order/OrderService.java:14`
       - `src/main/java/com/ex/order/OrderService.java:25`
     - 規格書位置：
       - `docs/spec/order-sd.md:42`
       - `docs/spec/order-sd.md:57`
  ```

  「判定」依扣分項與上游因素的 `source:` 對應：
  - 已扣分的意見列出對應的檢查代碼，例如 `A8`；對應不到檢查項的顯示「其他」，記為上游因素的顯示「上游因素」。
  - 不成立的顯示「不成立」，並多一行「不成立原因」。
  - `advisory` 外掛的意見顯示「僅供參考」。
- **二、評分結果**：各面向得分、問題明細、建議、上游因素、亮點、評分備註、結構化結果。
  - 得分表在七個面向之後，另列「其他（未對應檢查項）」與「上游因素」兩列的扣分。
  - 問題明細包含 Nit；由 CR 意見確認而來的扣分項會標示來源的意見編號。
  - 「建議（不扣分）」只放步驟 3 額外提出的建議。

報告開頭會同時列出評分等級與 CR 意見總數。版面與用語可在 `assets/report-template.md`、`assets/labels.tsv` 調整，可用的佔位符號見 `skills/code-review-scoring-report/references/placeholders.md`。

## 腳本為什麼存在

- `link-skills`：依 `skills/` 與 `configs/plugins.ini` 同步各工具的 Skill 連結，並在變更前檢查名稱與設定。
- `setup`：每次執行完整流程前檢查 `configs/plugins.ini` 與 `configs/settings.ini`，並以逐步詢問或指令的方式建立，登記外掛時先驗證，避免設定錯誤到 CR 步驟才發現。
- `review-state`：管理步驟狀態檔、規劃要執行的 CR 外掛、產生各步驟的指令，並強制依序執行；`next` 把查狀態、規劃外掛與產生指令合成一次呼叫，`finish` 直接執行步驟 4、5 的腳本，減少主 Agent 的往返次數與 token。
- `init-workspace` / `check-context`：固定交接檔案的位置，並在所有輸入資料與待確認問題處理完之前擋住後續步驟。
- `prepare-diff`：排除自動產生檔與 lock 檔、標上新檔行號、以評分標準的掃描規則檔列出啟發式候選，減少 AI 自行計算行號與重複掃描的 token。框架標準的 `applies` 沒有涵蓋的檔案標上 `[common]`，改用通用標準的掃描規則；檔案分類（`@scope`）與 PR 層級的提示（`@pr`，例如主程式有異動卻沒有測試檔）也寫在掃描規則檔中，腳本不含任何框架的判斷。
- `standard`：撰寫評分標準時檢查格式（`lint`），並把標準文件解析成腳本可讀的資料（`parse`）、列出兩個版本的差異（`diff`），挑出要評分的標準與通用標準、輸出檢查項、配分覆寫、適用檔案與掃描規則檔給 `score` 與 `prepare-diff`（`resolve`），在步驟 1 依異動檔案決定要產出哪幾份報告、切出各報告的 diff（`plan`），以及把審核通過的掃描規則草稿加上來源檔頭後寫入正式位置（`stamp`）。標準文件與 AI、腳本共用，格式寫錯時評分會讀錯規則，所以由腳本從嚴檢查：欄位數、嚴重度拼字、代碼重複、面向是否齊全、`standards.ini` 的配分加總與 `applies` 是否重疊，以及掃描規則的正規表示式是否只用 awk 與 .NET 共通的語法、引用的代碼是否還存在、是否在標準文件修改後過期。`lint` 只在撰寫或維護標準時執行，評分流程只透過 `plan` 與 `review-state` 的檢查呼叫 `resolve`，格式正確時不會輸出格式相關的訊息，不耗用 Token；格式有誤時直接停止（結束碼 2 或 3），請先執行 `lint` 修正。
- `score`：驗證評分結果（檢查代碼、嚴重度調整條件、位置是否在 diff 新增行、依 `merge` 設定檢查合併或逐筆扣分的寫法），並依 `configs/settings.ini` 的配分（評分標準在 `configs/standards.ini` 設定的 `points.*` 優先）計算分數與等級；檢查代碼與可用的嚴重度讀自評分標準文件，避免 AI 計算錯誤。`--check` 只做驗證、不寫檔，供步驟 3 在完成前自我檢查。
- `render-report`：依模板把 CR 結果與分數結果合併成一份報告並發佈到 `reports/`，數字與意見直接取自前面步驟的檔案，不經 AI 重打。

腳本的提示、訊息與註解一律使用英文，避免主控台編碼不同時出現亂碼。報告中由腳本插入的中文用語（含全形括號、冒號等符號）都放在 `skills/code-review-scoring-report/assets/labels.tsv`。

PowerShell 腳本以 UTF-8 with BOM 儲存，並在執行時將主控台與 git 輸出切換為 UTF-8，Windows PowerShell 5.1 也能正確處理中文。編輯 `.ps1` 時請保留 BOM。

在 Windows 的 Git Bash 執行 bash 腳本時，輸出與 Sub-Agent 指令中的路徑會使用 `C:/...` 格式，而不是 `/c/...` 或 `/tmp/...`，所以 Sub-Agent 不論改用 PowerShell 或 bash 都能找到同一個檔案。

三種腳本在相同輸入下的產出一致（已在 Windows 上以 PowerShell 5.1 與 Git Bash 驗證完整五步驟流程）。zsh 版由 bash 版轉換而來，修改 bash 版時請同步更新 zsh 版。
