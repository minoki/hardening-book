# サニタイザ

**サニタイザ**（sanitizer）は、コンパイラがプログラムに検査コードを埋め込み（計装、instrumentation）、実行時にメモリ安全性違反や未定義動作を検出するしくみです。オーバーヘッドが大きいので主に開発、テスト、ファジングで使いますが、バグを見つけることにかけては最も強力な道具です。

処理系開発者とサニタイザの関わり方は2つあります。1つは、ランタイムやFFI先のCコードをサニタイザ付きでビルドしてテストすることです。すぐに効果が出ますが、独自のアロケータやスタック切り替えを持つランタイムでは、注釈を入れないと誤検知や見逃しが起きます。もう1つは、自分の言語のコンパイラが計装を出力することです。RustやGo、Swiftはこれができ、`unsafe`なコードやFFI境界のバグ探しに役立てています。

## 一覧

| 名前 | オプション（Clang） | 検出するもの | 典型的な速度低下 |
|---|---|---|---|
| AddressSanitizer（ASan） | `-fsanitize=address` | 範囲外アクセス、use-after-free、double freeなど | 約2倍 |
| LeakSanitizer（LSan） | `-fsanitize=leak`（ASanに同梱） | メモリリーク | ほぼなし |
| MemorySanitizer（MSan） | `-fsanitize=memory` | 未初期化メモリの使用 | 約3倍 |
| UndefinedBehaviorSanitizer（UBSan） | `-fsanitize=undefined`など | 符号付き整数オーバーフロー、不正なシフトなど | 小〜中 |
| ThreadSanitizer（TSan） | `-fsanitize=thread` | データ競合 | 5〜15倍 |
| HWASan | `-fsanitize=hwaddress` | ASanとほぼ同じ（確率的） | ASanより小さい |

ASan、MSan、TSanはシャドウメモリの配置がぶつかるので同時には使えません。CIではそれぞれ別のビルドを用意します。UBSanはほかと組み合わせられます。

## AddressSanitizer（ASan）

### しくみ

ASanは、アプリケーションのメモリ8バイトごとに1バイトの**シャドウメモリ**を割り当て、そのメモリにアクセスしてよいかを記録します。

```text
shadow_addr = (addr >> 3) + Offset     // x86-64 Linux では Offset = 0x7fff8000

シャドウバイトの値:
   0      … 8バイトすべてアクセス可能
   1〜7   … 先頭の k バイトだけアクセス可能
   負の値 … アクセス不可（レッドゾーン、解放済みなど。値で種類を区別する）
```

コンパイラはロードとストアの前にシャドウの検査を挿入します。8バイトのロード`return *p;`をx86-64向けに`-O2 -fsanitize=address`でコンパイルすると、次のようになります。

```asm
load:
    pushq   %rax
    movq    %rdi, %rax
    shrq    $3, %rax                  # addr >> 3
    cmpb    $0, 2147450880(%rax)      # シャドウ（Offset = 0x7fff8000）が 0 か？
    jne     .LBB0_2
    movq    (%rdi), %rax              # 本来のロード
    popq    %rcx
    retq
.LBB0_2:
    callq   __asan_report_load8@PLT   # エラー報告（戻らない）
```

ヒープについては、ランタイムが`malloc`と`free`を差し替え、ブロックの前後にレッドゾーンを置きます。解放したメモリはしばらく再利用せず（quarantine）、解放済みとしてポイズンしておくことでuse-after-freeを検出します。スタックとグローバル変数には、コンパイラがレッドゾーンを付けます。`detect_stack_use_after_return`を有効にすると、ローカル変数を偽のスタック（fake stack）に置いて、use-after-returnも検出します。

```sh
clang -g -O1 -fno-omit-frame-pointer -fsanitize=address foo.c
ASAN_OPTIONS=detect_leaks=1:detect_stack_use_after_return=1 ./a.out
```

サニタイザの基本的な使い方は『Binary Hacks Rebooted』のHack #46で、シャドウメモリとレッドゾーンのしくみは提案論文に沿ってHack #47で解説しています。

### 独自アロケータに注釈を入れる

ランタイムが`malloc`から大きなチャンクを取って自分で切り分けている場合、ASanから見ればチャンク全体が1つの有効なオブジェクトです。**チャンク内での範囲外アクセスやuse-after-freeは検出されません**。これを補うのが手動ポイズニングのAPIです。

```c
#include <sanitizer/asan_interface.h>
#include <stddef.h>
#include <stdlib.h>

/* 単純なバンプアロケータ。ランタイムが大きなチャンクを確保して切り出す想定 */
typedef struct { char *base, *cur, *end; } Arena;

void arena_init(Arena *a, size_t size) {
    a->base = a->cur = malloc(size);
    a->end = a->base + size;
    /* まだ割り当てていない領域は全部「触ってはいけない」 */
    ASAN_POISON_MEMORY_REGION(a->base, size);
}

void *arena_alloc(Arena *a, size_t n) {
    char *p = a->cur;
    a->cur += (n + 15) & ~(size_t)15;   /* 16バイト境界に丸める */
    ASAN_UNPOISON_MEMORY_REGION(p, n);  /* 要求サイズぶんだけ解禁する */
    return p;
}

void arena_reset(Arena *a) {
    ASAN_POISON_MEMORY_REGION(a->base, a->end - a->base);
    a->cur = a->base;
}

int main(void) {
    Arena a;
    arena_init(&a, 4096);
    char *s = arena_alloc(&a, 10);
    s[9] = 'x';     /* OK */
    s[10] = 'y';    /* ASan: use-after-poison */
    return 0;
}
```

```text
==95580==ERROR: AddressSanitizer: use-after-poison on address 0xe39a70be010a ...
WRITE of size 1 at 0xe39a70be010a thread T0
    #0 0xb418eaa7745c in main arena.c:32:11
```

`ASAN_POISON_MEMORY_REGION`は、ASanが無効なときは何もしない式に展開されるので、ソースに入れっぱなしにできます。ASanビルドかどうかは`__has_feature(address_sanitizer)`（Clang）や`__SANITIZE_ADDRESS__`（GCC）で判定できます。

注釈の効果を上げるコツは次の通りです。

- ASanビルドのときだけ、オブジェクトの間に16バイトほどのレッドゾーンを空けます。隙間がないと、隣への範囲外アクセスは検出できません。
- ASanビルドのときだけ、解放したメモリをしばらく再利用しないようにします。
- シャドウの粒度は8バイトなので、オブジェクトの先頭は8バイト（できれば16バイト）境界にそろえます。
- capacityと長さが異なるベクタ型のバッファには、`__sanitizer_annotate_contiguous_container()`を使うと「capacity内だが長さ外」へのアクセスも検出できます。

### GCのスキャン

スタックやヒープを総なめにする保守的GCは、ASanと相性がよくありません。スキャン中にレッドゾーンや解放済み領域を読むと、エラーとして報告されてしまいます。スキャン関数には`__attribute__((no_sanitize("address")))`を付けて計装から外しましょう。

`detect_stack_use_after_return`が有効だと、ローカル変数は本物のスタックではなくfake stackにあります。`__asan_get_current_fake_stack()`と`__asan_addr_is_in_fake_stack()`でfake stackもスキャンするか、このオプションを切ってテストします。

### スタック切り替えと非局所脱出

コルーチンやグリーンスレッドでスタックを切り替えると、ASanはスタックの範囲を見失い、誤検知や不正確なレポートを出します。ファイバー用のAPIで切り替えを通知します。

```c
#include <sanitizer/common_interface_defs.h>

void switch_to(Coroutine *from, Coroutine *to) {
    void *fake_stack_save = NULL;
    /* これから to のスタックに切り替えることを通知する */
    __sanitizer_start_switch_fiber(&fake_stack_save, to->stack_bottom, to->stack_size);
    raw_context_switch(&from->ctx, &to->ctx);   /* アセンブリで書いた切り替え処理 */
    /* 戻ってきたら（別のコルーチンから from に切り替えられたら）完了を通知する */
    __sanitizer_finish_switch_fiber(fake_stack_save, NULL, NULL);
}
```

終了するコルーチンから切り替えるときは、`fake_stack_save`に`NULL`を渡すとそのfake stackが破棄されます。

関数の出口を通らずにフレームを捨てる非局所脱出では、捨てたフレームのポイズンが残り、後で同じ領域を使うときに誤検知が起きます。`longjmp`やC++の例外はASanが面倒を見てくれますが、処理系が独自に実装した例外機構や継続では、脱出の前に`__asan_handle_no_return()`を呼ぶ必要があります。

## LeakSanitizer（LSan）

LSanは、終了時にヒープとルート（スタック、レジスタ、グローバル変数）をスキャンし、どこからも参照されていない`malloc`ブロックをリークとして報告します。やっていることは保守的GCのマークフェーズそのものです。

ランタイムがタグ付きポインタや圧縮ポインタを使っていたり、独自に`mmap`した領域にだけポインタを置いていたりすると、LSanはポインタを見つけられずに誤検知します。`__lsan_ignore_object()`、`__lsan_register_root_region()`、`__lsan_disable()`と`__lsan_enable()`で対処します。

## MemorySanitizer（MSan）

MSanは、メモリの1ビットごとに初期化済みかを記録し、未初期化の値が条件分岐やポインタ参照、システムコールの引数に使われた時点で報告します。

最大の注意点は、**プログラムのすべてのコードが計装されている必要がある**ことです。計装されていないコードの書き込みはMSanに見えないので、そのメモリは未初期化のままとみなされます。libc++もMSan付きでビルドしたものがいります。処理系で問題になるのは、手書きのアセンブリ、JITで生成したコード、MSanの計装を出力しない自前のコード生成器のコードです。

これらがCの領域に書き込んだら`__msan_unpoison(ptr, size)`を呼びます。自前のコード生成器を持つ言語では、FFI境界でまとめてアンポイズンするのが現実的な妥協点でしょう。`-fsanitize-memory-track-origins=2`を付けると、未初期化の値の出どころも報告されます。対応プラットフォームは主にLinuxです。

## UndefinedBehaviorSanitizer（UBSan）

UBSanは、C/C++の未定義動作の一部を検出します。個別に有効にでき、オーバーヘッドも比較的小さめです。

```sh
# 代表的な組み合わせ
clang -fsanitize=undefined ...
# ランタイムライブラリなしで、違反時に trap 命令を実行する（本番でも使える）
clang -fsanitize=undefined -fsanitize-trap=undefined ...
# Clang独自: 未定義動作ではないが、多くの場合バグである符号なし整数のラップなども検出
clang -fsanitize=integer ...
```

Cを中間言語にしている処理系なら、生成したCコードをUBSan付きでコンパイルすると、コード生成器のバグが見つかります。

一方、LLVM IRを生成する処理系では、UBSanは何もしてくれません。UBSanの計装はClangのフロントエンドが入れるからです。`nsw`や`inbounds`、`noundef`などのフラグを誤って付けると、LLVMの最適化は想定外のコードを生成します。Alive2で最適化の正しさを確かめたり、デバッグビルドでフラグを外して挙動を比べたりするのが有効です。

## ThreadSanitizer（TSan）

TSanは、すべてのメモリアクセスと同期操作を記録し、happens-before関係のない同時アクセスを検出します。ランタイムで気を付けたいのは次の点です。

- アトミック命令を直接使ったロックや、futexを直接たたくコードは、同期として認識されないことがあります。`__tsan_acquire(addr)`と`__tsan_release(addr)`で伝えます。
- ファイバーには`__tsan_create_fiber()`、`__tsan_switch_to_fiber()`、`__tsan_destroy_fiber()`を使います。
- GCのstop-the-worldをシグナルで実装していると、誤検知が出ることがあります。
- 言語独自のメモリモデルが、TSanの前提であるC/C++11のメモリモデルと合っているか確かめましょう。Goの`-race`は、TSanのランタイムをGoのメモリモデルに合わせて使っています。

## HWASan

HWASanは、AArch64の**TBI**（Top Byte Ignore。ポインタの最上位バイトをハードウェアが無視する機能）を使って、ポインタにタグを埋め込むASanの変種です。割り当て時にランダムな8ビットのタグを選び、ポインタの最上位バイトと、16バイトごとのシャドウの両方に書きます。アクセス時に両者を比べ、一致しなければエラーです。

```asm
// AArch64, -fsanitize=hwaddress での return *p;（抜粋）
    ubfx    x9, x0, #4, #52        // アドレス >> 4（タグを除く）
    lsr     x8, x0, #56            // ポインタのタグ（最上位バイト）
    ldrb    w9, [x20, x9]          // メモリのタグ（シャドウ）
    cmp     w8, w9
    b.ne    .LBB0_2                // 不一致なら報告
    ldr     x0, [x0]               // 本来のロード
```

レッドゾーンやquarantineがいらないのでメモリ使用量が少なく、Androidではシステム全体をHWASanでビルドしてテストすることもあります。これをハードウェアで実現したものがMTEです。ポインタの最上位バイトをランタイムが自分で使っていると衝突しますが、この問題はMTEの章で扱います。

## 本番で使えるもの：GWP-ASanとScudo

**GWP-ASan**は、割り当てのごく一部をサンプリングしてガードページ付きの領域に置きます。オーバーヘッドはほぼゼロで、大量のユーザー環境で動かせばいつかバグを踏みます。Chrome、Android、Appleのプラットフォームなどで使われています。

**Scudo**はLLVMのhardened allocatorで、Androidのデフォルトのアロケータです。チャンクヘッダのチェックサムや割り当て位置のランダム化、quarantineを備え、MTEにも対応しています。メタデータとデータの分離やサイズクラスごとの領域分離など、独自アロケータを設計するときの参考になります。

## 自分の言語をサニタイザに対応させる

### LLVMバックエンドの場合

LLVMのサニタイザは、ほとんどがIRレベルのパスです。関数に`sanitize_address`などの属性を付け、パイプラインに`AddressSanitizerPass`などを追加し、compiler-rtのランタイムをリンクすれば、ロード、ストア、スタック変数の計装はほぼ自動で入ります。Rust（`-Zsanitizer=address`）やSwift（`-sanitize=address`）はこの方式です。

ただし、GCヒープなど言語独自のヒープには、前述の手動ポイズニングが必要です。境界検査で安全とわかっているアクセスに`nosanitize`メタデータを付けて計装を省くと、オーバーヘッドを減らせます。

### 自前のバックエンドの場合

自前のコード生成器でも、ASanのランタイムは流用できます。起動時に`__asan_init()`を呼び、ロードとストアの前に前述のシャドウ検査を出力して、違反時に`__asan_report_load8(addr)`などを呼び、`libclang_rt.asan`をリンクするのが最小構成です。ヒープの検査は`malloc`の差し替えで自動的に得られ、スタックやグローバル変数のレッドゾーンは後回しにできます。シャドウのオフセットはプラットフォームごとに決まっているので（compiler-rtの`asan_mapping.h`）、それに合わせます。

Goの`go build -asan`や`-msan`は、Goのコンパイラが出力した計装からCのサニタイザランタイムを呼びます。こうすることで、cgoでCと共有するメモリのバグを両側から検出できます。

## ファジングとの組み合わせ

サニタイザはファジングと組み合わせると威力を発揮します。libFuzzerやAFL++でランタイム、パーサ、FFI境界の関数をたたき、ASanやUBSanで異常を捕まえます。処理系そのものをファジングするのも有効です。特にJITや最適化器の誤コンパイルは、生成コードのメモリ安全性違反として表に出ることが多く、サニタイザ付きのファジングでよく見つかります。

ファジングの概要とAFL++の使い方は『Binary Hacks Rebooted』のHack #60とHack #61に、LibAFLによるファザーの実装はHack #62とHack #63にあります。
