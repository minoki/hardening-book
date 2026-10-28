# 基本的な緩和策のおさらい

命令セット拡張に入る前に、昔からある緩和策を処理系開発者の目線で振り返ります。どれも「Cコンパイラにフラグを付ければ有効になる」と思われがちですが、独自のコード生成器を持つ処理系では、自分で対応しないと有効にならないものが多くあります。

## NXとW^X

**NX**（No-eXecute。ArmではXN）は、ページ単位で実行を禁止するハードウェア機能です。これを使って「書き込めるメモリは実行できず、実行できるメモリは書き込めない」状態を保つのが**W^X**（Write XOR Execute）です。

### `.note.GNU-stack`を忘れない

ELFのLinuxでは、オブジェクトファイルの`.note.GNU-stack`セクションでスタックを実行可能にするかが決まります。このセクションがないオブジェクトは「実行可能スタックが必要かもしれない」とみなされ、1つでも混ざると実行ファイル全体のスタックが実行可能になることがあります。

GCCやClangは自動で出力しますが、自前でアセンブリを出力する処理系や手書きのアセンブリでは忘れがちです。

```asm
    .section .note.GNU-stack,"",%progbits   # 生成するすべての .s に入れる
```

binutils 2.39以降の`ld`は次のような警告を出すので、出たら必ず直しましょう。

```text
warning: foo.o: missing .note.GNU-stack section implies executable stack
warning: a.out has a LOAD segment with RWX permissions
```

`readelf -lW a.out | grep GNU_STACK`でフラグが`RW`になっていることも確認できます。glibc 2.41からは、実行可能スタックを要求する共有ライブラリを`dlopen`するとエラーになるので、この問題は「動かない」という形で表に出るようになってきました。

### トランポリンとJIT

GCCの入れ子関数のアドレスを取ると、スタック上にトランポリンが作られ、スタックの実行許可が必要になります。クロージャの実装でこれを真似してはいけません。基本は「関数ポインタ＋環境ポインタ」の組で表し、どうしても関数ポインタ1つで呼べるクロージャが必要なら、実行可能領域にあらかじめ用意したトランポリンのプールを使います（libffiのclosure APIがこの方式を取れます）。

JITは本質的に「書いてから実行する」ので、W^Xとの両立に工夫がいります。

| 方法 | 内容 | 注意 |
|---|---|---|
| `mprotect`で切り替え | RWで書いてRXに変える | システムコールが重い。RWの瞬間を他スレッドに突かれうる |
| 二重マッピング | 同じ物理ページをRWとRXの2つの仮想アドレスにマップする | RW側のアドレスが漏れると意味がない |
| Apple Siliconの`MAP_JIT` | `pthread_jit_write_protect_np()`でスレッドごとにWとXを切り替える | Hardened Runtimeでは`com.apple.security.cs.allow-jit`エンタイトルメントが必要 |
| メモリ保護キー | スレッドごとにページの書き込み権限を切り替える | 「そのほかの機構」の章を参照 |

W^Xを守りながら実行時に機械語を生成する簡単な例は、『Binary Hacks Rebooted』のHack #85にあります。

## ASLRとPIE

ASLR（Address Space Layout Randomization）は、スタック、ヒープ、共有ライブラリ、実行ファイルのロードアドレスをランダムにします。実行ファイル自体をランダムな位置に置くには、PIE（Position Independent Executable）である必要があります。

コード生成器は、グローバル変数や関数のアドレスをPC相対かGOT経由で得る、位置独立なコードを生成します。絶対アドレスをコードに埋め込むと、ロード時にコードを書き換えるテキストリロケーション（`DT_TEXTREL`）が生じてW^Xを破ります。`-z text`でリンクすれば、これをエラーにできます。

エラーメッセージやデバッグ出力、アドレスを種にしたハッシュ値からアドレスが漏れると、ASLRの効果は薄れます。ASLRの実装と回避手法は『Binary Hacks Rebooted』のHack #55で、`-static`で静的リンクするとASLRが効かなくなる話はHack #13で扱っています。

## RELRO

動的リンクでは、関数や変数のアドレスがGOT（Global Offset Table）に書き込まれます。書き換え可能なGOTは格好の標的なので、再配置が終わったら読み取り専用にします。これがRELRO（RELocation Read-Only）です。

- `-Wl,-z,relro`：部分RELRO。遅延束縛用の`.got.plt`は書き込み可能なまま残ります。
- `-Wl,-z,relro,-z,now`：完全RELRO。起動時にすべてのシンボルを解決し、GOT全体を読み取り専用にします。

ランタイムが持つディスパッチテーブルやvtable、型情報も、初期化後に読み取り専用にできないか検討しましょう。コンパイル時に決まるなら`const`にして`.rodata`や`.data.rel.ro`に置くのが簡単です。

## スタックカナリア

**スタックカナリア**（stack protector）は、ローカル配列とリターンアドレスの間にランダムな値を置き、関数から戻る前に変わっていないか確かめます。

```c
// -fstack-protector-strong で生成されるコードのイメージ
void f(const char *s) {
    uintptr_t canary = __stack_chk_guard;   // x86-64 glibc では %fs:0x28
    char buf[16];
    strcpy(buf, s);
    if (canary != __stack_chk_guard)
        __stack_chk_fail();                 // 異常終了
}
```

推奨は、配列やアドレスを取られたローカル変数を持つ関数を対象にする`-fstack-protector-strong`です。カナリアの置き場所は、x86-64のglibcではTLS（`%fs:0x28`）、AArch64のglibcではグローバル変数`__stack_chk_guard`です。独自のコード生成器で実装するなら、Cコンパイラと同じ場所を参照するとランタイムと整合が取れます。カナリアの有無でスタックフレームがどう変わるかは、『Binary Hacks Rebooted』のHack #59でアセンブリを見ながら観察しています。

カナリアは連続的なオーバーフローには効きますが、任意アドレス書き込みやカナリアの漏洩には無力です。後の章のShadow StackやPACは、より強いbackward edgeの保護を提供します。

## スタッククラッシュ保護

スタックの下には通常ガードページがありますが、一度に大きなフレームを確保すると、ガードページを飛び越えてヒープや他スレッドのスタックに入り込めます（Stack Clash、2017年）。`-fstack-clash-protection`は、大きなフレームを確保するときにページごとにメモリに触り（probe）、必ずガードページを踏ませます。

```asm
# x86-64, 大きなフレームを確保するときのイメージ
.Lprobe:
    sub   $4096, %rsp
    orq   $0, (%rsp)        # 1ページごとに触る
    cmp   %r11, %rsp
    jne   .Lprobe
```

**独自のコード生成器では、大きなスタックフレームや可変長配列、`alloca`相当の機能、エスケープ解析によるスタック割り当てを実装するときに、この対策を自分で入れる必要があります**。Windowsでは昔から`__chkstk`によるprobeが必須なので、Windows対応済みの処理系なら同じしくみを流用できます。

## Cで書いたランタイムのためのフラグ

ランタイムやFFI先のCコードには、ディストリビューションが標準で使っているhardeningフラグを付けておきましょう。代表的なものを挙げます（詳しくはOpenSSFの *Compiler Options Hardening Guide for C and C++* を参照）。

| フラグ | 効果 |
|---|---|
| `-O2 -D_FORTIFY_SOURCE=3` | `memcpy`などに、サイズがわかる範囲で境界検査を入れる（=3はGCC 12、Clang 16以降） |
| `-fstack-protector-strong` | スタックカナリア |
| `-fstack-clash-protection` | スタッククラッシュ保護 |
| `-fcf-protection=full`（x86-64） | Intel CETに対応したコードを生成 |
| `-mbranch-protection=standard`（AArch64） | BTIとPAC（pac-ret）に対応したコードを生成 |
| `-ftrivial-auto-var-init=zero` | 未初期化の自動変数をゼロで初期化 |
| `-fPIE -pie`、`-fPIC` | 位置独立コード |
| `-Wl,-z,relro,-z,now` | 完全RELRO |
| `-Wl,-z,noexecstack` | 実行可能スタックを要求しない |
| `-fno-delete-null-pointer-checks`、`-fno-strict-overflow`、`-fno-strict-aliasing` | 未定義動作を理由に安全性チェックが最適化で消されるのを防ぐ |

GCC 14以降には、これらの多くをまとめて有効にする`-fhardened`もあります。
