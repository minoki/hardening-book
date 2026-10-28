# Arm BTI

**BTI**（Branch Target Identification）は、Armv8.5-Aで導入されたAArch64のforward edge保護です。「間接分岐の飛び先は`BTI`命令で始まらなければならない」という考え方はIntel CETのIBTと同じですが、分岐の種類とlanding padの種類の組み合わせを区別する点が少し細かくなっています。

## しくみ

### Guarded page

BTIの検査は、ページテーブルでGP（Guarded Page）ビットが立っているページ上のコードに対してだけ行われます。Linuxでは`mmap`や`mprotect`の`PROT_BTI`フラグでこのビットを立てます。ページ単位で決まるので、BTI対応のコードと非対応のコードを混在させられます。

### 分岐の種類とlanding pad

間接分岐を実行すると、CPUは分岐の種類を`PSTATE.BTYPE`に記録します。飛び先がguarded page上にあれば、その命令が`BTYPE`と互換かを検査し、互換でなければ例外を発生させます（Linuxではプロセスに`SIGILL`が送られます）。

| 分岐命令 | BTYPE |
|---|---|
| `BR x16`、`BR x17`（PAC付きの`BRAA`なども含む） | 01 |
| `BLR xN`（PAC付きの`BLRAA`なども含む） | 10 |
| `BR xN`（x16、x17以外） | 11 |

| landing pad | 受け付けるBTYPE | 用途 |
|---|---|---|
| `BTI c` | 01、10 | 関数の入口 |
| `BTI j` | 01、11 | ジャンプテーブル、計算型goto、ランディングパッド |
| `BTI jc` | すべて | 両方 |
| `PACIASP`、`PACIBSP` | 01、10 | 関数の入口。暗黙の`BTI c`として振る舞う |

`RET`と直接分岐（`B`、`BL`）は検査されません。

注目してほしいのは、**x16／x17経由の`BR`が「call」扱いになる**点です。x16とx17はAAPCS64でIP0／IP1と呼ばれる一時レジスタで、リンカが生成するveneer（遠い関数への中継コード）やPLTが使います。これらが`BTI c`の関数に飛べるように、この規則があります。

`BTI`、`PACIASP`、`AUTIASP`はヒント命令の空間にあり、非対応のCPUではNOPになります。BTIやPACに対応したバイナリも、古いCPUでそのまま動きます。

## 有効にする方法

```sh
gcc -mbranch-protection=bti ...       # BTI のみ
gcc -mbranch-protection=standard ...  # BTI + PAC (pac-ret)
```

Intel CETの章と同じCコードを、AArch64向けにGCCの`-O2 -mbranch-protection=standard`でコンパイルした結果です。

```asm
h:
    hint    34 // bti c        ← アドレスを取られる static 関数
    lsl     w0, w0, 1
    ret
f:
    hint    25 // paciasp      ← PACIASP が暗黙の BTI c を兼ねる
    ...
    blr     x1
    ...
    bl      g
    ...
    hint    29 // autiasp
    ret
get:
    hint    34 // bti c
    adrp    x0, h
    add     x0, x0, :lo12:h
    ret
```

`f`の先頭に`bti c`がないのは、`paciasp`がその役目を兼ねているからです。

### `BTI j`が置かれる場所

GCC 13とClang 21で確かめると、次の場所に`bti j`が置かれます。

```c
#include <setjmp.h>
jmp_buf jb;
int sj(void){ if (setjmp(jb)) return 1; a(); return 0; }
int interp(const unsigned char *pc){
    static void *t[]={&&l0,&&l1}; int acc=0;
    goto *t[*pc++]; l0: acc++; goto *t[*pc++]; l1: return acc;
}
void tail(void (*f)(void)){ f(); }
```

```asm
sj:
    hint    25 // paciasp
    ...
    bl      _setjmp
    hint    36 // bti j        ← setjmp から2回目に戻ってくる地点（longjmp は BR で戻る）
    ...
interp:
    hint    34 // bti c
    ...
    br      x2
.L18:
    hint    36 // bti j        ← 計算型 goto のラベル
    ...
tail:
    hint    34 // bti c
    br      x16                ← 間接末尾呼び出しは x16 を使う → 飛び先は bti c でよい
```

C++の`catch`節の入口にも`bti j`が置かれます。アンワインダが`BR`でランディングパッドに飛ぶからです。

```asm
_Z1fv:
    hint    25 // paciasp
    bl      _Z1gv
    ...
.L4:
    hint    36 // bti j        ← catch 節（ランディングパッド）
    bl      __cxa_begin_catch
```

### ELFプロパティ

BTI対応のオブジェクトは、`.note.gnu.property`の`GNU_PROPERTY_AARCH64_FEATURE_1_AND`にBTIビット（`1`）を持ちます。pac-retを使っていればPACビット（`2`）も付きます。

```text
$ readelf -n foo.o
      Properties: AArch64 feature: BTI, PAC
```

x86と同じく、出力には全入力の論理積が設定されます。

### Linuxでの有効化

Linux 5.8以降で、ユーザー空間のBTIが使えます。静的リンクの実行ファイルと動的リンカ自身にはカーネルが、動的リンクされる実行ファイルと共有ライブラリには動的リンカ（glibc 2.32以降）が、BTIプロパティを見て`PROT_BTI`を付けます。

IBTやShadow Stackと違い、BTIはELFファイル単位で有効になります。プロパティのない共有ライブラリはguarded pageにならないだけで、プロセス全体の保護が無効になるわけではありません。

### 実際の環境での落とし穴

ディストリビューションのスタートアップファイルが、BTIに対応していないことがあります。執筆時点のUbuntu 24.04（arm64）で確かめた結果です。

```text
$ for f in /usr/lib/aarch64-linux-gnu/{Scrt1.o,crti.o} \
           /usr/lib/gcc/aarch64-linux-gnu/13/crtbeginS.o \
           /lib/aarch64-linux-gnu/libc.so.6; do
    echo "$f: $(readelf -n $f | grep 'AArch64 feature')"; done
/usr/lib/aarch64-linux-gnu/Scrt1.o:
/usr/lib/aarch64-linux-gnu/crti.o:
/usr/lib/gcc/aarch64-linux-gnu/13/crtbeginS.o:       Properties: AArch64 feature: BTI, PAC
/lib/aarch64-linux-gnu/libc.so.6:
```

**つまりこの環境では、`-mbranch-protection=standard`でコンパイルしても、実行ファイルにBTIプロパティが付きません**。`-z force-bti`を付けると、原因となった入力が警告で示されます。

```text
$ gcc main.o helper.o -Wl,-z,force-bti
ld: .../Scrt1.o: warning: BTI turned on by -z force-bti when all inputs do not have BTI in NOTE section.
ld: .../crti.o: warning: BTI turned on by -z force-bti when all inputs do not have BTI in NOTE section.
ld: helper.o: warning: BTI turned on by -z force-bti when all inputs do not have BTI in NOTE section.
```

Fedoraのように、ディストリビューション全体を`-mbranch-protection=standard`でビルドしているところもあります。ターゲットとする環境ごとに、自分の処理系が出力したバイナリにBTIプロパティが付いているか確かめましょう。

## コード生成器が気を付けること

### landing padの置き場所

| 場所 | landing pad |
|---|---|
| 外部から見える関数、アドレスを取られる関数の入口 | `BTI c`（`PACIASP`を出力するなら不要） |
| ジャンプテーブルの飛び先 | `BTI j` |
| 計算型goto、direct threadingのハンドラ | `BTI j` |
| `setjmp`相当の関数の呼び出し直後 | `BTI j` |
| 例外のランディングパッド | `BTI j` |
| 関数の入口で、かつ`BR`でも飛ばれる場所 | `BTI jc` |

### 間接末尾呼び出しにはx16／x17を使う

関数ポインタやクロージャ経由の末尾呼び出しでは`BR xN`を使います。**x16かx17を使えば、飛び先は`BTI c`で受けられます**。それ以外のレジスタでは、飛び先に`BTI j`か`BTI jc`が必要になり、普通の関数には飛べなくなります。末尾呼び出しを多用する関数型言語や、インタプリタからJITコードへ`BR`で遷移する処理系は、レジスタ割り当ての段階で間接末尾呼び出しのターゲットをx16／x17に固定しましょう。

### 自前のアセンブリとリンク

コンテキスト切り替えやFFIのトランポリンなど、手書きのアセンブリにも`bti c`や`bti j`を入れ、`.note.gnu.property`を付けます。アセンブラはこのノートを自動では付けないので、次のように自分で書きます。コード生成器が`.s`を出力する場合も同じです。

```asm
/* GNU_PROPERTY_AARCH64_FEATURE_1_AND: BTI(1) | PAC(2) */
    .section .note.gnu.property,"a"
    .p2align 3
    .word 4          /* n_namesz */
    .word 16         /* n_descsz */
    .word 5          /* n_type = NT_GNU_PROPERTY_TYPE_0 */
    .asciz "GNU"
    .word 0xc0000000 /* pr_type = GNU_PROPERTY_AARCH64_FEATURE_1_AND */
    .word 4          /* pr_datasz */
    .word 3          /* BTI | PAC */
    .word 0          /* padding */
```

リンク時に`-z bti-report=error`（GNU ld、lld）を付ければ、BTI非対応の入力をエラーにできます。

## ランタイム・FFIで気を付けること

### JIT

JITコードをguarded pageに置くなら、`mmap`／`mprotect`で`PROT_EXEC | PROT_BTI`を指定し、生成コードの間接分岐の飛び先に`BTI`命令を入れます。

`PROT_BTI`を付けなければ`BTI`命令がなくても動きますが、JITコードのどこにでも間接分岐で飛べてしまいます。JITコードは攻撃者がある程度内容をコントロールできることが多いので、**JITこそBTIで守るべき場所です**。なお、systemdの`MemoryDenyWriteExecute=`が有効な環境では、`mprotect`で`PROT_EXEC`を付けること自体が禁止されることがあります。

### コールバックとシグナルハンドラ

Cから関数ポインタで呼ばれる関数は`BLR`で呼ばれるので、`BTI c`が必要です。コールバックや`qsort`の比較関数、スレッドのエントリ関数として処理系の関数をCに渡すときは注意しましょう。シグナルハンドラもカーネルから関数として呼ばれるので、同じく`BTI c`が必要です。

## テスト

QEMU（`qemu-aarch64 -cpu max`）はBTIをエミュレートするので、非対応のマシンでもテストできます。実際にguarded pageになっているかは、`/proc/<pid>/smaps`の`VmFlags`に`bt`があるかで確認できます。
