# Arm Pointer Authentication

**Pointer Authentication**（PAC、PAuth）は、Armv8.3-Aで導入されたAArch64の機能です。ポインタの使われていない上位ビットに暗号学的な署名（PAC：Pointer Authentication Code）を埋め込み、使う前に検証します。署名を偽造できない攻撃者は、ポインタを書き換えても検証で弾かれます。

最もよく使われるのはリターンアドレスの保護（**pac-ret**）です。Appleのプラットフォーム（arm64e）では、関数ポインタやvtableなど、さらに多くのポインタが署名されています。

## しくみ

### 署名と検証

```text
PAC = 暗号関数(鍵, ポインタ, modifier) の一部のビット
署名:  PACIA x, m   … x の上位ビットに PAC を埋め込む
検証:  AUTIA x, m   … PAC を再計算して比較。一致すれば上位ビットを元に戻す
                       一致しなければ x を不正なポインタにする（またはトラップする）
```

鍵は、命令ポインタ用のIAとIB、データポインタ用のDAとDB、汎用のGAの5種類です。鍵はシステムレジスタにあり、ユーザー空間からは読み書きできません。Linuxでは`exec`のたびにランダムに設定され、`fork`した子プロセスとスレッドは同じ鍵を共有します。

modifierは任意の64ビット値です。同じポインタでもmodifierが違えばPACも変わるので、別の場所で署名されたポインタの流用を防げます。

PACのビット数は、仮想アドレスの幅とTBIの設定で決まります。Linuxで仮想アドレスが48ビットなら、データポインタで7ビット、命令ポインタで15ビット程度です。総当たりで当たる可能性はゼロではないので、検証に失敗したら即座にプロセスを終了させる前提の設計です。

### 主な命令

| 命令 | 動作 |
|---|---|
| `PACIASP`、`PACIBSP` | LR（x30）を、SPをmodifierとしてIA／IB鍵で署名 |
| `AUTIASP`、`AUTIBSP` | LRを、SPをmodifierとして検証 |
| `RETAA`、`RETAB` | LRを検証してから戻る |
| `PACIA`、`PACDA`など | 任意のレジスタを任意のmodifierで署名 |
| `AUTIA`、`AUTDA`など | 任意のレジスタを検証 |
| `BLRAA`、`BRAA`など | 検証してから間接分岐 |
| `LDRAA`、`LDRAB` | データポインタを検証してからロード |
| `XPACI`、`XPACD`、`XPACLRI` | 検証せずにPACを取り除く |
| `PACGA` | 汎用のMACを計算 |

`PACIASP`、`AUTIASP`、`XPACLRI`などはヒント命令の空間にあり、非対応のCPUではNOPです。`-mbranch-protection=pac-ret`でコンパイルしたバイナリが古いCPUでも動くのはこのためです。一方、`RETAA`や`BLRAA`はArmv8.3以降でしか動きません。

### 検証に失敗したとき

当初の仕様では、`AUT*`は失敗しても例外を起こさず、ポインタの上位ビットを壊して「使うとフォールトするアドレス」にするだけでした。Armv8.6で導入されたFEAT_FPACがあれば、`AUT*`が失敗した時点で例外が発生します。Linuxではこれは`SIGILL`（`si_code`は`ILL_ILLOPN`）として通知されます。

## pac-ret：リターンアドレスの保護

### 生成されるコード

```sh
gcc -mbranch-protection=pac-ret ...       # LR を保存する関数だけ
gcc -mbranch-protection=pac-ret+leaf ...  # リーフ関数も含めてすべて
gcc -mbranch-protection=pac-ret+b-key ... # IB 鍵を使う
gcc -mbranch-protection=standard ...      # BTI + pac-ret
```

```asm
f:
    paciasp                    // LR を SP で署名（暗黙の BTI c も兼ねる）
    stp     x29, x30, [sp, -32]!
    ...
    ldp     x29, x30, [sp], 32
    autiasp                    // LR を検証
    ret
```

スタックに保存されるのは署名済みのリターンアドレスです。攻撃者がスタックを書き換えても、正しいPACを計算できないので`autiasp`で検出されます。modifierがSPなので、同じ関数の別の呼び出しで保存されたリターンアドレスを流用することもできません。

### 実験

FEAT_FPACに対応したAArch64のLinuxで、保存されたリターンアドレスを見たり書き換えたりしてみます。

```c
#include <stdio.h>
#include <stdint.h>

static inline uintptr_t strip_pac(uintptr_t p) {
    /* XPACLRI は x30 の PAC を取り除く（ヒント命令なので非対応CPUではNOP） */
    register uintptr_t x30 __asm__("x30") = p;
    __asm__("hint 7" /* xpaclri */ : "+r"(x30));
    return x30;
}

__attribute__((noinline)) void show(void) {
    /* フレームレコード: fp[0] = 呼び出し元のFP, fp[1] = 保存されたLR */
    uintptr_t *fp = __builtin_frame_address(0);
    uintptr_t saved_lr = fp[1];
    printf("saved LR    = %#018lx\n", (unsigned long)saved_lr);
    printf("stripped LR = %#018lx\n", (unsigned long)strip_pac(saved_lr));
    printf("&show       = %p\n", (void *)&show);
}

__attribute__((noinline)) void smash(void) {
    volatile uintptr_t *fp = __builtin_frame_address(0);
    fp[1] ^= 4;   /* 保存されたリターンアドレスを1命令ずらす（ROPの真似） */
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    show();
    smash();
    puts("not reached?");
    return 0;
}
```

```text
$ gcc -O2 -fno-omit-frame-pointer -mbranch-protection=pac-ret pac.c -o pac && ./pac
saved LR    = 0x0018bd18d65e076c      ← 上位ビットに PAC が入っている
stripped LR = 0x0000bd18d65e076c
&show       = 0xbd18d65e08e0
Illegal instruction (core dumped)     ← smash の autiasp で検出（FEAT_FPAC により SIGILL）

$ gcc -O2 -fno-omit-frame-pointer pac.c -o nopac && ./nopac
saved LR    = 0x0000bbaded020768
stripped LR = 0x0000bbaded020768
&show       = 0xbbaded0208e0
（ずれたアドレスに戻って、そのまま暴走した）
```

PACなしのほうは、改ざんされたアドレスに黙って戻り、この実験では無限ループに陥りました。

### アンワインダとDWARF

C++の例外やバックトレース、デバッガ、プロファイラにとって、保存されたリターンアドレスが署名済みかどうかは重要な情報です。DWARFのCFIでは、`paciasp`の直後に`DW_CFA_AARCH64_negate_ra_state`（アセンブリでは`.cfi_negate_ra_state`）を置いて、ここから先はリターンアドレスが署名済みだと示します。

```asm
f:
    .cfi_startproc
    paciasp
    .cfi_negate_ra_state       // 以降、RA は署名済み
    stp     x29, x30, [sp, -16]!
    .cfi_def_cfa_offset 16
    .cfi_offset 29, -16
    .cfi_offset 30, -8
    ...
```

アンワインダはこれを見てPACを取り除きます。libgccとLLVMのlibunwindは対応済みです。

## Appleのarm64e

Appleのプラットフォームでは、システムのバイナリはarm64eというABIでビルドされ、リターンアドレス以外のポインタも署名されます。

| 対象 | 鍵 | modifier |
|---|---|---|
| リターンアドレス | IB | SP |
| Cの関数ポインタ | IA | 0 |
| C++のvtableポインタ | DA | オブジェクト内のアドレス（address diversity） |
| C++のvtableのエントリ | IA | エントリのアドレスとメソッドごとの定数の組み合わせ |
| Objective-Cの`isa`などのメタデータ | 種類ごとに決まっている | 種類ごとに決まっている |

C/C++からは、`<ptrauth.h>`の組み込み関数や`__ptrauth`修飾子でこれを扱えます。

```c
#include <ptrauth.h>

// 構造体のフィールドに署名付きの関数ポインタを持たせる。
// アドレス多様化（フィールドのアドレスを modifier に混ぜる）+ 定数 0x1234
struct Handler {
    void (*__ptrauth(ptrauth_key_function_pointer, 1, 0x1234) callback)(int);
};

// 署名されていない生のアドレスを関数ポインタとして使えるように署名する（JITなど）
void (*fp)(void) = ptrauth_sign_unauthenticated(
    (void (*)(void))code_addr, ptrauth_key_function_pointer, 0);

// PAC を取り除いて生のアドレスを得る（比較やハッシュ、デバッグ表示など）
void *raw = ptrauth_strip((void *)fp, ptrauth_key_function_pointer);
```

ELF向けにも、arm64eと同様に関数ポインタなどを署名するABI（PAuth ABI）の開発がLLVMで進んでいます。

## コード生成器が気を付けること

pac-retを自前のコード生成器で実装するときの規則は次の通りです。

1. LRをスタックに保存する前に署名し、復元した後に検証します。
2. 署名時と検証時でSPを同じ値にします。可変長のスタック割り当てなどでSPを動かしたら、エピローグで元に戻してから`autiasp`を実行します。
3. 末尾呼び出しの前に検証します。LRはそのままcalleeに渡るので、署名したまま飛ぶとcalleeが署名を重ね、最後に壊れたアドレスへ戻ってしまいます。
4. `.cfi_negate_ra_state`を出力します。これがないと、例外の巻き戻しやバックトレースが壊れます。
5. LRを一時的に別のレジスタへ退避するときも、署名の状態を追跡し続けます。

```asm
// 末尾呼び出しの正しい例
g:
    paciasp
    stp     x29, x30, [sp, -16]!
    ...
    ldp     x29, x30, [sp], 16
    autiasp                     // ここで LR を元に戻す
    br      x16                 // 末尾呼び出し（BTI のために x16 を使う）
```

pac-retを使ったオブジェクトには、`GNU_PROPERTY_AARCH64_FEATURE_1_AND`のPACビット（`2`）を付けます。今のLinuxはこのビットを見て何かを強制はしませんが、ツールがバイナリの性質を判断するのに使います。

## ランタイム・FFIで気を付けること

### スタック上のリターンアドレスを読むコード

**GC、例外処理、プロファイラなど、スタックを歩いてリターンアドレスを読むコードは、必ずPACを取り除いてから使います**。さもないと、GCのスタックマップや例外テーブルの検索、シンボル化がすべて「該当なし」になります。`XPACI`や`XPACLRI`は署名されていないアドレスに使っても何も変わらないので、常に取り除くようにしておくのが簡単です。`XPACLRI`はヒント命令なので、PAC非対応のCPUでも動きます。

### スタックの移動とコピー

pac-retのmodifierはSPです。したがって、**スタックの内容を別のアドレスにコピーすると、コピー先ではリターンアドレスの検証が失敗します**。スタックのコピーによる継続、Goのようにスタックを丸ごとコピーして伸ばす方式、スナップショットの保存と書き戻しが影響を受けます。

対策は3通りです。コピーしたフレームのリターンアドレスを新しいSPで署名し直すか、生成コードではpac-retを使わずにShadow StackやGCSに頼るか、スタックを移動しない設計にするかです。署名し直す場合は、ランタイムがフレームのレイアウトを完全に把握している必要があります。しかも署名し直すコード自体が「任意のアドレスに署名できるガジェット」になりうるので注意が必要です。

### コルーチンの初期化とreturn address hijacking

新しいコルーチンに「エントリ関数へ`ret`で入るための偽のフレーム」を用意する実装では、偽のリターンアドレスが`autiasp`の検証に失敗します。新しいコルーチンには`br`で入るか、フレームが使われるときのSPで正しく署名しておきます。

GCのセーフポイントのためにリターンアドレスを書き換える手法も、正しいmodifierで署名し直さない限り失敗します。ランタイムに任意のアドレスを署名させることになるので、慎重に設計しましょう。

### arm64eでのFFIとJIT

arm64eでCとやりとりする関数ポインタは署名されています。Cから受け取った関数ポインタは`BLRAAZ`（IA鍵、modifier 0で検証して呼ぶ）で呼び、Cに渡すコールバックやJITコードのエントリはIA鍵、modifier 0で署名してから渡します。関数ポインタに算術演算をしたり整数として比較したりするなら、先に`ptrauth_strip`でPACを取り除きます。Objective-CやC++のオブジェクトを直接触るなら、それぞれのランタイムの署名方式に従う必要があります。

### 自分のランタイムでPACを使う

PACはランタイムのデータ構造を守るのにも使えます。メソッドテーブルやクロージャのコードポインタを、格納場所のアドレスをmodifierにして`PACIA`で署名しておき、呼ぶときに`BLRAA`で検証すれば、ヒープの書き換えによる制御の乗っ取りを防げます。GCのメタデータへのポインタを`PACDA`で署名して`LDRAA`で読めば、データ専用攻撃の一部も防げます。

## 限界

- PACのビット数は少ないので、プロセスが再起動される、`fork`した子プロセスが同じ鍵を持つ、といった状況では総当たりの余地があります。
- 同じmodifierを持つ場所どうしでの入れ替えは防げません。arm64eがmodifierにアドレスや型ごとの定数を混ぜているのはこのためです。
- 2022年には、投機的実行を使ってPACを総当たりするPACMAN攻撃が発表されました。
- 任意の値を署名して返してしまうガジェットがあると、保護は無力化されます。

## テスト

QEMU（`qemu-aarch64 -cpu max`）はPACをエミュレートします。実機では、Apple SiliconのMac、AWS Graviton3以降、最近のスマートフォンのSoCなどがPACに対応しています。
