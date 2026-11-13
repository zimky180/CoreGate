模块只生成一个保留全部源码注释的 ZIP，包含编译后的 Rust 只读观察程序。
命令：python3 tools/package_module.py --output out --binary /path/to/coregated
仅使用 Python 标准库，打包前检查 Shell 语法、版本与 ELF 架构，打包后检查 ZIP 完整性及文件逐字节一致性。
模块版本与 Rust 组件版本独立：只提升模块版本时复用已验证二进制；修改 Rust 代码时重新编译。
