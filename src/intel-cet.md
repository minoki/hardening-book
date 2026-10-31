# Intel CET

**Intel CET**（Control-flow Enforcement Technology）は、x86-64に追加された制御フロー保護の機能で、2つの機構から成ります。

- **IBT**（Indirect Branch Tracking）：forward edgeの粗いCFIです。間接`call`／`jmp`の飛び先は`ENDBR64`命令で始まらなければなりません。
- **Shadow Stack**：backward edgeの保護です。`call`のたびにリターンアドレスを別のスタックにも積み、`ret`で照合します。

IntelではTiger Lake（第11世代Core）以降、AMDではZen 3以降がShadow Stackに対応しています（AMDにはShadow Stackのみに対応した世代があります）。

## IBT

### しくみ

IBTが有効なとき、CPUは間接`call`／`jmp`を実行すると「次の命令は`ENDBR64`でなければならない」状態に入ります。そうでなければ制御保護例外（`#CP`）が発生します。

```asm
caller:
    call  *%rax          # 間接呼び出し → 飛び先は ENDBR64 で始まる必要がある

callee:
    endbr64              # landing pad
    ...
```

`ENDBR64`は、CET非対応のCPUではNOPとして扱われます。`ENDBR64`を入れたバイナリは古いCPUでもそのまま動きます。

### NOTRACK接頭辞

間接分岐に`notrack`接頭辞（`3E`）を付けると、その分岐ではIBTの検査が省かれます。GCCもClangも、`switch`文のジャンプテーブルによる間接ジャンプに`notrack`を付けます（GCC 13とClang 21で確認）。テーブルは読み取り専用なので書き換えられない、という前提です。ただ、インデックスの範囲チェックを迂回できるバグがあれば悪用されうるので、使用は最小限にとどめるべきとされます。

### コンパイラのオプション

```sh
gcc   -fcf-protection=full ...   # IBT と Shadow Stack の両方（branch + return）
gcc   -fcf-protection=branch ... # IBT のみ
gcc   -fcf-protection=return ... # Shadow Stack のみ
```

UbuntuのGCCでは`-fcf-protection`がデフォルトで有効ですが、Clangでは明示的に指定する必要があります。

Clangでx86-64向けに`-fcf-protection=full`を付けると、次のようになります。

```c
extern int g(int);
int (*fp)(int);
int f(int x){ return fp(x) + g(x) + 1; }
static int h(int x){ return x*2; }
int (*get(void))(int){ return h; }
```

```asm
f:
    endbr64                  # 外部から関数ポインタで呼ばれるかもしれない
    ...
    callq   *fp(%rip)
    ...
get:
    endbr64
    leaq    h(%rip), %rax
    retq
h:
    endbr64                  # static だがアドレスを取られているので必要
    leal    (%rdi,%rdi), %eax
    retq
```

`static`でアドレスを取られない関数なら、`endbr64`は省略されます。

### ELFプロパティ

IBTやShadow Stackに対応したオブジェクトであることは、`.note.gnu.property`セクションの`GNU_PROPERTY_X86_FEATURE_1_AND`で示します。

```text
$ readelf -n foo.o
Displaying notes found in: .note.gnu.property
  Owner                Data size        Description
  GNU                  0x00000010       NT_GNU_PROPERTY_TYPE_0
      Properties: x86 feature: IBT, SHSTK
```

名前の`_AND`が示すように、リンカは全入力のビットの論理積を出力に設定します。**1つでもプロパティのないオブジェクトが混ざると、そのプログラムでは保護が有効になりません**。しかもデフォルトでは警告すら出ません。

```sh
# プロパティのない手書きアセンブリを混ぜてリンクした例
$ gcc -fcf-protection main.c helper.s -o a.out
$ readelf -n a.out | grep 'x86 feature'
(何も出ない = 保護が無効)

# -z cet-report=warning を付けると警告が出る
$ gcc -fcf-protection main.c helper.s -Wl,-z,cet-report=warning
ld: /tmp/ccHwXCxG.o: warning: missing IBT and SHSTK properties
```

GNU ldには、プロパティがなければエラーにする`-z cet-report=error`、入力によらずプロパティを付ける`-z ibt`と`-z shstk`もあります。後者は、中身が対応していないのに付けると実行時にクラッシュするので注意してください。

### OSの対応状況

カーネル自身のIBTはLinux 5.18以降で有効です（FineIBTは6.2以降）。一方、ユーザー空間のIBTは執筆時点でLinuxのメインラインに入っていません。Windowsはforward edgeの保護にCFGを使い、IBTは使っていません。

それでも、今のうちから`ENDBR64`を正しく出力しておくべきです。UbuntuやFedoraなどのディストリビューションは、すでにパッケージをIBT対応でビルドしています。将来ユーザー空間のIBTが有効になったとき、自分の処理系のバイナリだけが対応していないと、プロセス全体で保護が無効になってしまいます。

## Shadow Stack

### しくみ

Shadow Stackが有効なとき、CPUは通常のスタックとは別に、Shadow Stack Pointer（SSP）が指すShadow Stackを管理します。

```text
call f:  通常のスタックに戻り先を push、Shadow Stack にも戻り先を push
ret:     通常のスタックから pop した戻り先と、Shadow Stack から pop した戻り先を比較
         一致しなければ #CP（Linux では SIGSEGV, si_code = SEGV_CPERR）
```

Shadow Stackのページは、ページテーブル上でWrite=0かつDirty=1という特殊な組み合わせを持ち、通常の`mov`命令では書き込めません。書き込めるのは`call`などの命令と、専用の命令だけです。

| 命令 | 動作 |
|---|---|
| `RDSSPQ` | SSPを読む（Shadow Stackが無効なときはNOPなので、事前に0を入れておけば判定に使える） |
| `INCSSPQ n` | Shadow Stackからn個のエントリを捨てる（`longjmp`などで使う。Shadow Stackが無効なときは`#UD`になるので、`RDSSPQ`で確かめてから使う） |
| `RSTORSSP`、`SAVEPREVSSP` | トークンを使ってShadow Stackを切り替える |
| `WRSSQ` | Shadow Stackに書き込む（OSが許可した場合のみ） |

### Linuxでの利用

Linux 6.6以降、ユーザー空間でShadow Stackを使えます。有効にするのはglibcで、実行ファイルとすべての共有ライブラリが`SHSTK`プロパティを持っていれば、起動時に`arch_prctl(ARCH_SHSTK_ENABLE, ARCH_SHSTK_SHSTK)`を呼びます。glibc 2.39では有効化はオプトインで、チューナブル`glibc.cpu.hwcaps=SHSTK`で有効にし、`glibc.cpu.x86_shstk`で有効化後の挙動を選びます（デフォルトはディストリビューションによって異なります）。

```sh
# Shadow Stack を有効にして実行（対応CPUとカーネルが必要。Ubuntu 24.04で確認）
GLIBC_TUNABLES=glibc.cpu.hwcaps=SHSTK ./a.out
```

有効化後にプロパティのないライブラリを`dlopen`すると、`rebuild shared object with SHSTK support enabled`というエラーで失敗します。`glibc.cpu.x86_shstk=permissive`ならShadow Stackを無効にして読み込み、`=on`ならプロパティを無視してShadow Stackを有効にしたまま読み込みます。新しいスレッドのShadow Stackはカーネルが割り当て、追加のShadow Stackは`map_shadow_stack(2)`で確保できます。シグナルハンドラを呼ぶときは、カーネルがShadow Stackにも情報を積み、`sigreturn`で検証します。

### Windowsでの利用

Windowsでは「Hardware-enforced Stack Protection」の名前でユーザーモードのShadow Stackを使えます。リンカオプション`/CETCOMPAT`でマークした実行ファイルで有効になり、例外による巻き戻しや`longjmp`にはOSとCRTが対応しています。

## コード生成器が気を付けること

### `ENDBR64`を置く場所

| 場所 | 理由 |
|---|---|
| 外部から見える関数の先頭 | 共有ライブラリや関数ポインタ経由で呼ばれうる |
| アドレスを取られる関数の先頭 | 関数ポインタ、クロージャ、vtable経由で呼ばれる |
| 間接ジャンプの飛び先 | ジャンプテーブル（`notrack`を使わない場合）、計算型goto |
| `setjmp`のような「2回戻る」関数の呼び出し直後 | `longjmp`は間接ジャンプで戻ってくる |
| 独自の例外機構のランディングパッド | アンワインダが間接ジャンプで飛ぶ場合 |

GCCもClangも、`returns_twice`属性の関数の呼び出し直後や計算型gotoのラベルには、自動で`endbr64`を入れます。direct threadingのインタプリタをアセンブリで書いているなら、すべてのハンドラの先頭に自分で入れる必要があります。

逆に、不要な`ENDBR64`は置かないことも大事です。`ENDBR64`がある場所はすべて正当な飛び先とみなされるので、数が増えるほど攻撃者の選択肢も増えます。

### `call`と`ret`を対にする

Shadow Stackはプログラムの書き換えを必要としないので、普通のコードはそのまま動きます。壊れるのは、`call`と`ret`の対応を崩すコードです。

| パターン | 例 | 対処 |
|---|---|---|
| `push`してから`ret`で飛ぶ | 間接ジャンプの代わりに`push target; ret` | `jmp *%reg`を使う |
| スタック上のリターンアドレスを書き換える | GCのためのreturn address hijacking | 別の方法に変える（後述） |
| `call`の戻り先を`pop`で捨てる | `call 1f; ...; 1: pop %rax` | Shadow Stack側は残るので、以降の`ret`がずれる。32ビットPICの定番`call next; next: pop`だけは、変位0の`call`がShadow Stackに積まれないので動く。x86-64ではRIP相対の`lea`を使う |
| `ret`せずにフレームを捨てる | 独自の例外機構、継続 | `INCSSPQ`でShadow Stackも巻き戻す |
| retpoline | Spectre v2対策で間接分岐を`call`と`ret`で表す | Shadow Stackとは両立しない |

`jmp`による末尾呼び出しは`call`を使わないので、Shadow Stackと問題なく両立します。

## ランタイム・FFIで気を付けること

### スタック切り替え

**コルーチンやグリーンスレッド、ファイバーでスタックを切り替える処理系は、Shadow Stackも一緒に切り替える必要があります**。手順の概略は次の通りです。

1. コルーチンごとに`map_shadow_stack(addr, size, SHADOW_STACK_SET_TOKEN)`でShadow Stackを確保します。先頭にはリストアトークンが置かれます。
2. 切り替え先のトークンに対して`RSTORSSP`を実行してから、`SAVEPREVSSP`で切り替え元のShadow Stackにトークンを残します。逆の順序では例外になります。
3. 新しいコルーチンのエントリ関数には、`ret`ではなく`jmp`で入ります。Shadow Stackにはまだ戻り先がないからです。

glibcの`makecontext`と`swapcontext`は対応済みなので、これらを使っていれば自動で処理されます。アセンブリで独自のコンテキスト切り替えを書いているなら自分で対応する必要があり、glibcやBoost.Contextの実装が参考になります。スタックを伸長する処理系では、Shadow Stackのサイズも別途考えておきます。リターンアドレスしか積まないので小さくて済みますが、再帰の深さには比例します。

### 継続とスタックのコピー

スタックの内容をコピーして後で書き戻す方式の継続は、**Shadow Stackとは基本的に両立しません**。通常のスタックは書き戻せても、Shadow Stackは普通の命令では書き戻せないからです。Linuxには`WRSS`を許可する`ARCH_SHSTK_WRSS`もありますが、保護を弱めます。しかもglibcは通常、起動時にこの設定をロックするので、後から有効にしようとしても`EPERM`で失敗します（`permissive`のときを除く）。

継続ごとに独立したスタック（とShadow Stack）を割り当てる、ワンショットの継続に制限してスタック切り替えで実装する、CPS変換でスタックに依存しない実装にする、といった設計の変更を検討しましょう。

### GCとreturn address hijacking

スレッドを安全な地点で止めるために、スタック上のリターンアドレスを書き換え、関数から戻った瞬間にランタイムへ制御を移すランタイムがあります。この手法はShadow Stackと衝突します。たとえば.NETランタイムは、CETに対応する際にこの手法への対処が必要になりました。ループや関数の入口でフラグを確かめるセーフポイントのポーリングなら、この問題は起きません。

### FFI

Cから呼ばれるコールバックの先頭には`ENDBR64`が必要です。また、自前のアセンブリやコード生成器のオブジェクトにELFプロパティを付け忘れると、プロセス全体の保護が無効になります。`-z cet-report=error`でリンクして確かめましょう。

## 確認とテスト

`readelf -n`で`x86 feature: IBT, SHSTK`が付いているか、`objdump -d`で間接分岐の飛び先に`endbr64`があるかを確認します。

実機がなければ、Intel SDE（Software Development Emulator）でCETを有効にして実行するのが手軽です。

```sh
sde64 -cet -cet_stderr -cet_abort -- ./a.out
```

`-cet_abort`を付けないと、違反してもメッセージが出ないまま`SIGSEGV`で終わることがあります。付けると、Shadow Stackの違反なら期待した戻り先と実際の戻り先が、IBTの違反なら直前の間接分岐が表示されます。

『Binary Hacks Rebooted』のHack #57では、Hack #56で組み立てたROPによる攻撃がSDE上のShadow Stackで止まる様子を見ています。

LinuxでShadow Stackの違反が起きると、`SIGSEGV`（`si_code`は`SEGV_CPERR`）でプロセスが終了し、カーネルログにも`control protection ip:... error:1(near ret)`のような行が残ります（プログラムが`SIGSEGV`を自分で処理した場合は残りません）。
