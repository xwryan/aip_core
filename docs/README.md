# AIP Core 文档

这里是 AIP Core 的统一文档入口。文档面向使用或集成 AIP Core 的验证工程师，覆盖
SystemVerilog/UVM 接入、Tcl/UCLI 交互、TCP 远程命令、CPU mailbox、DUT 后门控制、
日志与参数配置，以及构建、回归和故障排查。快速了解项目可先阅读根目录
[`README.md`](../README.md)；需要完整的操作说明和功能参考时使用下面的用户手册。

## 用户手册

- [AIP Core 用户手册（DOCX）](AIP_Core_Environment_Guide.docx)
- [Markdown 源文件](source/AIP_Core_Environment_Guide.md)

DOCX 是面向使用者的交付版本，Markdown 是唯一需要维护的手册源文件。修改手册内容
后，请从项目根目录重新生成 DOCX，并在交付前完成验证。不要直接编辑生成的 DOCX，
否则下一次生成会覆盖手工修改。

## 重新生成 DOCX

先将 `TECHNICAL_MANUAL_DOCX_SKILL` 设置为本机已安装的 `technical-manual-docx` skill
目录，然后执行：

```sh
export TECHNICAL_MANUAL_DOCX_SKILL=/path/to/technical-manual-docx
python3 "$TECHNICAL_MANUAL_DOCX_SKILL/scripts/build_docx.py" \
  --input docs/source/AIP_Core_Environment_Guide.md \
  --output docs/AIP_Core_Environment_Guide.docx
```

命令应在仓库根目录执行。`--input` 指向唯一的 Markdown 源文件，`--output` 指向供
用户下载的 DOCX；如果只想试生成，可将输出改到临时目录，确认结果后再替换仓库中的
交付文件。

## 验证 DOCX 和 PDF

验证器会检查 DOCX 包是否完整，并尝试导出 PDF，以便检查目录、书签、标题层级、表格、
代码块和分页。将 PDF 输出目录设置为临时目录后执行：

```sh
export AIP_MANUAL_PDF_DIR="$(mktemp -d)"
python3 "$TECHNICAL_MANUAL_DOCX_SKILL/scripts/validate_docx.py" \
  docs/AIP_Core_Environment_Guide.docx \
  --pdf-dir "$AIP_MANUAL_PDF_DIR"
```

验证通过后，可使用 Word 或 LibreOffice 打开 DOCX；也可以用 PDF 工具检查导出页数、
目录文字和末页内容。PDF 是验证产物，不作为仓库交付文件提交。

## 其他文档

- [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md)：已知问题、适用条件和临时规避方案。这里记录
  当前实现的限制，不替代用户手册中的正常用法。
- [`superpowers/`](superpowers/)：设计 spec、实施 plan 和评审记录，仅用于项目维护
  和变更追踪，不是面向最终用户的操作说明。

## 文档维护约定

1. 用户可见的功能、参数、返回值、集成步骤和示例写入 Markdown 源文件。
2. 生成 DOCX 后运行验证器，并确认内部目录和链接可用。
3. 需要记录限制或临时方案时更新 `KNOWN_ISSUES.md`，同时在手册中保留稳定的使用说明。
4. 设计讨论和实施记录放在 `superpowers/`，不在根 README 或用户手册中复制内部过程。
