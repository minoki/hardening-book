# 参考文献

この分野は変化が速いので、実装の際は一次資料で最新の情報を確認してください。

## 全般

- OpenSSF, *Compiler Options Hardening Guide for C and C++*
  <https://best.openssf.org/Compiler-Hardening-Guides/Compiler-Options-Hardening-Guide-for-C-and-C++>
- The rustc book, *Exploit Mitigations*（Rustがどの緩和策をどう実装しているかの解説。ほかの言語の処理系にも参考になります）
  <https://doc.rust-lang.org/rustc/exploit-mitigations.html>
- M. Abadi, M. Budiu, Ú. Erlingsson, J. Ligatti, *Control-Flow Integrity*, CCS 2005

## サニタイザ

- Clangのドキュメント（AddressSanitizer、MemorySanitizer、ThreadSanitizer、UndefinedBehaviorSanitizer、HardwareAssistedAddressSanitizerDesign）
  <https://clang.llvm.org/docs/AddressSanitizer.html>
- google/sanitizersのWiki
  <https://github.com/google/sanitizers/wiki>
- compiler-rtの公開ヘッダ（`asan_interface.h`、`common_interface_defs.h`、`lsan_interface.h`、`msan_interface.h`、`tsan_interface.h`）
  <https://github.com/llvm/llvm-project/tree/main/compiler-rt/include/sanitizer>

## CFI

- Clang, *Control Flow Integrity*
  <https://clang.llvm.org/docs/ControlFlowIntegrity.html>
- Clang, *ShadowCallStack*
  <https://clang.llvm.org/docs/ShadowCallStack.html>
- Clang, *SafeStack*
  <https://clang.llvm.org/docs/SafeStack.html>
- Microsoft, *Control Flow Guard for platform security*
  <https://learn.microsoft.com/en-us/windows/win32/secbp/control-flow-guard>

## Intel CET

- Intel 64 and IA-32 Architectures Software Developer's Manual, Volume 1, Chapter "Control-flow Enforcement Technology (CET)"
- Linux kernel documentation, *Control-flow Enforcement Technology (CET) Shadow Stack*
  <https://docs.kernel.org/arch/x86/shstk.html>
- x86-64 psABI（`GNU_PROPERTY_X86_FEATURE_1_AND`の定義）
  <https://gitlab.com/x86-psABIs/x86-64-ABI>
- Microsoft, */CETCOMPAT (CET Shadow Stack compatible)*
  <https://learn.microsoft.com/en-us/cpp/build/reference/cetcompat>

## Arm（BTI、PAC、MTE、GCS）

- Arm Architecture Reference Manual for A-profile architecture
  <https://developer.arm.com/documentation/ddi0487/latest>
- Arm, *ABI for the Arm 64-bit Architecture*（AAPCS64と、ELFの`GNU_PROPERTY_AARCH64_FEATURE_1_AND`の定義を含む）
  <https://github.com/ARM-software/abi-aa>
- Linux kernel documentation
  - *Pointer authentication in AArch64 Linux* <https://docs.kernel.org/arch/arm64/pointer-authentication.html>
  - *Memory Tagging Extension (MTE) in AArch64 Linux* <https://docs.kernel.org/arch/arm64/memory-tagging-extension.html>
  - *AArch64 TAGGED ADDRESS ABI* <https://docs.kernel.org/arch/arm64/tagged-address-abi.html>
  - *Guarded Control Stack* <https://docs.kernel.org/arch/arm64/gcs.html>
- Apple, *Preparing your app to work with pointer authentication*
  <https://developer.apple.com/documentation/security/preparing-your-app-to-work-with-pointer-authentication>
- Clang, *Pointer Authentication*（`<ptrauth.h>`と`__ptrauth`の解説）
  <https://clang.llvm.org/docs/PointerAuthentication.html>
- Android, *Arm Memory Tagging Extension*
  <https://source.android.com/docs/security/test/memory-safety/arm-mte>
- Android, *Tagged Pointers*
  <https://source.android.com/docs/security/test/tagged-pointers>
- Apple Security Research, *Memory Integrity Enforcement*
  <https://security.apple.com/blog/memory-integrity-enforcement/>

## その他

- RISC-V, *RISC-V Control-flow Integrity (CFI)*（Zicfiss、Zicfilpの仕様）
  <https://github.com/riscv/riscv-cfi>
- CHERIプロジェクト（ケンブリッジ大学）
  <https://www.cl.cam.ac.uk/research/security/ctsrd/cheri/>
- J. Ravichandran et al., *PACMAN: Attacking ARM Pointer Authentication with Speculative Execution*, ISCA 2022
- J. Kim et al., *TikTag: Breaking ARM's Memory Tagging Extension with Speculative Execution*, 2024
