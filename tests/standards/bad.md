---
name: Bad_Name
applies: "*.java"
color: red
---

# 錯誤案例

## 面向

| 代碼 | 面向 | 衡量重點 |
| --- | --- | --- |
| A | 正確性 | x |
| B | 安全 | x |
| B | 安全性 | x |
| H | 其他 | x |
| C | 測試品質 | x |
| D | 架構與設計 | x |
| E | 效能與資源使用 | x |
| F | 可讀性 | x |

## 檢查項

- 這裡是說明，不會被解析：`- 代碼｜內容｜預設嚴重度`

### A. 正確性

- A1｜正常的檢查項｜Major
- A1｜重複的代碼｜Major
- A2|半形分隔|Major
- A3｜欄位數錯誤｜Major｜Critical
- A4｜嚴重度拼錯｜major
- A5｜可調整為預設值｜Minor｜Minor｜條件
- A6｜可調整為 Nit｜Minor｜Major,Nit｜條件
- A7｜沒有條件｜Minor｜Major｜
- B1｜放錯面向｜Major
- CM-A8｜框架標準用了 CM｜Major
- 沒有分隔符號的項目
- A9｜續行測試，第一行
  第二行｜Minor

```text
- A10｜程式碼區塊中的範例｜Major
```

<!-- - A11｜註解中的範例｜Major -->

這行是多餘的文字

### B. 安全

- B2｜｜Critical

### X. 不存在的面向

#### 太深的標題

### C. 測試品質

### D. 架構與設計

無

### E. 效能與資源使用

- E1｜正常｜Minor

## 事先確認事項

- A1, Z9｜確認不存在的代碼
- A1｜
- A1|半形

## 檢查項

<!-- 沒有關閉的註解
