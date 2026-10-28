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
| `INCSSPQ n` | Shadow Stackからn個のエントリを捨てる（`longjmp`などで使う） |
| `SAVEPREVSSP`、`RSTORSSP` | トークンを使ってShadow Stackを切り替える |
| `WRSSQ` | Shadow Stackに書き込む（OSが許可した場合のみ） |

### Linuxでの利用

Linux 6.6以降、ユーザー空間でShadow Stackを使えます。有効にするのはglibcで、実行ファイルとすべての共有ライブラリが`SHSTK`プロパティを持っていれば、起動時に`arch_prctl(ARCH_SHSTK_ENABLE, ARCH_SHSTK_SHSTK)`を呼びます。glibc 2.39以降はチューナブル`glibc.cpu.x86_shstk`で挙動を制御できます（デフォルト値はディストリビューションによって異なります）。

```sh
# Shadow Stack を強制的に有効にして実行（対応CPUとカーネルが必要）
GLIBC_TUNABLES=glibc.cpu.x86_shstk=on ./a.out
```

有効化後にプロパティのないライブラリを`dlopen`すると失敗します（設定によってはShadow Stackを無効にして続行します）。新しいスレッドのShadow Stackはカーネルが割り当て、追加のShadow Stackは`map_shadow_stack(2)`で確保できます。シグナルハンドラを呼ぶときは、カーネルがShadow Stackにも情報を積み、`sigreturn`で検証します。

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
| `call`で現在位置を得る | 32ビットPICの定番`call next; next: pop %rax` | `pop`してもShadow Stack側は残るので、以降の`ret`がずれる。x86-64ではRIP相対の`lea`を使う |
| `ret`せずにフレームを捨てる | 独自の例外機構、継続 | `INCSSPQ`でShadow Stackも巻き戻す |
| retpoline | Spectre v2対策で間接分岐を`call`と`ret`で表す | Shadow Stackとは両立しない |

`jmp`による末尾呼び出しは`call`を使わないので、Shadow Stackと問題なく両立します。

## ランタイム・FFIで気を付けること

### スタック切り替え

**コルーチンやグリーンスレッド、ファイバーでスタックを切り替える処理系は、Shadow Stackも一緒に切り替える必要があります**。手順の概略は次の通りです。

1. コルーチンごとに`map_shadow_stack(addr, size, SHADOW_STACK_SET_TOKEN)`でShadow Stackを確保します。先頭にはリストアトークンが置かれます。
2. 切り替え元で`SAVEPREVSSP`によりトークンを残し、切り替え先に対して`RSTORSSP`を実行します。
3. 新しいコルーチンのエントリ関数には、`ret`ではなく`jmp`で入ります。Shadow Stackにはまだ戻り先がないからです。

glibcの`makecontext`と`swapcontext`は対応済みなので、これらを使っていれば自動で処理されます。アセンブリで独自のコンテキスト切り替えを書いているなら自分で対応する必要があり、glibcやBoost.Contextの実装が参考になります。スタックを伸長する処理系では、Shadow Stackのサイズも別途考えておきます。リターンアドレスしか積まないので小さくて済みますが、再帰の深さには比例します。

### 継続とスタックのコピー

スタックの内容をコピーして後で書き戻す方式の継続は、**Shadow Stackとは基本的に両立しません**。通常のスタックは書き戻せても、Shadow Stackは普通の命令では書き戻せないからです。Linuxには`WRSS`を許可する`ARCH_SHSTK_WRSS`もありますが、保護を弱めます。

継続ごとに独立したスタック（とShadow Stack）を割り当てる、ワンショットの継続に制限してスタック切り替えで実装する、CPS変換でスタックに依存しない実装にする、といった設計の変更を検討しましょう。

### GCとreturn address hijacking

スレッドを安全な地点で止めるために、スタック上のリターンアドレスを書き換え、関数から戻った瞬間にランタイムへ制御を移すランタイムがあります。この手法はShadow Stackと衝突します。たとえば.NETランタイムは、CETに対応する際にこの手法への対処が必要になりました。ループや関数の入口でフラグを確かめるセーフポイントのポーリングなら、この問題は起きません。

### FFI

Cから呼ばれるコールバックの先頭には`ENDBR64`が必要です。また、自前のアセンブリやコード生成器のオブジェクトにELFプロパティを付け忘れると、プロセス全体の保護が無効になります。`-z cet-report=error`でリンクして確かめましょう。

## 確認とテスト

`readelf -n`で`x86 feature: IBT, SHSTK`が付いているか、`objdump -d`で間接分岐の飛び先に`endbr64`があるかを確認します。

実機がなければ、Intel SDE（Software Development Emulator）でCETを有効にして実行するのが手軽です。

```sh
sde -cet -cet-stderr -- ./a.out
```

LinuxでShadow Stackの違反が起きると、`SIGSEGV`（`si_code`は`SEGV_CPERR`）でプロセスが終了し、カーネルログにも`control protection fault`と記録されます。
