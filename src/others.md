# そのほかの機構

本章では、ここまでに扱わなかった関連機構を駆け足で紹介します。どれも処理系の実装に影響しうるものです。

## Arm GCS（Guarded Control Stack）

**GCS**は、Armv9.4-Aで導入されたAArch64のShadow Stackです。`BL`や`BLR`でLRの値がGCSにも積まれ、`RET`でx30とGCSの先頭を照合します。GCSのページは通常のストア命令では書き込めず、スタックの切り替えには`GCSSS1`／`GCSSS2`とトークンを、`longjmp`相当の巻き戻しには`GCSPOPM`を使います。

pac-retとの違いは、PACが署名の偽造を難しくする確率的な保護なのに対し、GCSは決定的に検出する点です。その代わり、スタックのコピーやreturn address hijackingとの相性はPAC以上に悪くなります。

執筆時点のソフトウェアの対応状況は次の通りです。

- Linux 6.13以降でユーザー空間のGCSをサポートしています。`prctl(PR_SET_SHADOW_STACK_STATUS, ...)`で有効にし、追加のGCSはx86と共通の`map_shadow_stack(2)`で確保します。
- ELFプロパティ`GNU_PROPERTY_AARCH64_FEATURE_1_AND`のGCSビット（`4`）で対応を示します。
- GCC 15以降に`-mbranch-protection=gcs`があり、glibc 2.41以降が対応しています。

Intel CETの章で述べたスタック切り替え、非局所脱出、継続の注意点は、そのままGCSにも当てはまります。x86とAArch64の両方をターゲットにする処理系は、Shadow Stackへの対応を共通の設計にしておくとよいでしょう。

## RISC-VのCFI拡張（Zicfiss／Zicfilp）

RISC-Vにも、2024年に批准された制御フロー保護の拡張があります。

- **Zicfiss**はShadow Stackです。プロローグの`sspush`でリターンアドレスを積み、エピローグの`sspopchk`で照合します。
- **Zicfilp**はlanding padです。間接分岐の飛び先に`lpad`命令を要求し、`lpad`には20ビットのラベルを付けられます。ラベルに関数の型のハッシュを入れれば、ハードウェアで型ベースのCFIができます。

`call`と`ret`が自動で積み下ろしするx86やAArch64と違い、Shadow Stackの操作をコード生成器が明示的に出力する点が大きな違いです。Linuxやツールチェインでの対応も進められています。

## メモリ保護キー

**メモリ保護キー**は、ページごとにキーを割り当て、スレッドごとのレジスタでキーごとのアクセス権を切り替えられるようにする機能です。

| | x86-64 | AArch64 |
|---|---|---|
| 名前 | PKU（Protection Keys for Userspace） | POE（Permission Overlay Extension） |
| 切り替え | `WRPKRU`命令（ユーザー空間から実行可能） | `POR_EL0`レジスタへの書き込み |
| Linux API | `pkey_alloc(2)`、`pkey_mprotect(2)`、`pkey_set(3)` | 同じAPI（Linux 6.12以降） |

システムコールなしで権限を切り替えられるので、JITのW^X（V8はWebAssemblyのコード領域の保護にPKUを使っています）や、GCのメタデータの保護、信頼できないCライブラリを呼ぶ間だけ言語のヒープを書き込み禁止にするサンドボックスなどに使えます。ただし、攻撃者が`WRPKRU`そのものを実行できると突破されるので、CFIなどとの組み合わせが前提です。

## ポインタの上位ビットを無視する機能

64ビットのポインタのうち、実際のアドレスに使うのは下位48（または57）ビット程度です。上位ビットを無視するハードウェア機能を使えば、タグを埋め込んだまま参照できます。

| アーキテクチャ | 機能 | 無視されるビット |
|---|---|---|
| AArch64 | TBI（Top Byte Ignore） | 最上位8ビット（データアクセスのみ） |
| x86-64（Intel） | LAM（Linear Address Masking） | LAM_U57：6ビット、LAM_U48：15ビット |
| x86-64（AMD） | UAI（Upper Address Ignore） | 最上位7ビット |
| RISC-V | Pointer Masking | 設定による |

これらはHWASanやMTEの基盤で、ランタイムが独自のタグ付きポインタを実装するのにも便利です。しかしMTEの章で見たように、同じビットをOSやアロケータ、サニタイザも使いたがるので奪い合いになります。**上位ビットをランタイムの用途に使う設計は、将来の互換性のリスクを抱えます**。

なおLinuxでIntel LAMを使うには`arch_prctl(ARCH_ENABLE_TAGGED_ADDR, ...)`で明示的に有効にする必要があり、投機的実行への懸念から、カーネルの設定やCPUによっては使えないことがあります。

## CHERI

**CHERI**（Capability Hardware Enhanced RISC Instructions）は、ケンブリッジ大学などが開発している、ポインタをケーパビリティ（アドレス、境界、権限、改ざん検出用のタグビットの組）に置き換えるアーキテクチャ拡張です。Armの試作ボードMorelloや、組み込み向けのCHERIoTで実装されています。

境界外アクセスはハードウェアが確実に検出し、ケーパビリティは整数から作り出せません。空間的安全性は確実に得られ、時間的安全性もアロケータとの協調で得られます。

言語処理系への影響は大きく、ポインタが128ビットになって`sizeof(void*) != sizeof(size_t)`となり、整数からポインタを作れないのでNaN-boxingやポインタ圧縮が使えなくなります。一方で、タグビットのおかげでGCがポインタを確実に判別できるという利点もあります。

## 投機的実行への対策

Spectreなどの投機的実行の脆弱性への対策もhardeningの一種で、信頼できないコードを実行するJITを持つ処理系（JavaScriptエンジン、WebAssemblyランタイムなど）は特に影響を受けます。

| 対策 | 内容 |
|---|---|
| インデックスのマスキング | 境界検査の後、投機的に範囲外を読まないよう、インデックスを範囲内にマスクする |
| Speculative Load Hardening | 分岐予測ミスを検出してロードアドレスを無効化する（Clangの`-mspeculative-load-hardening`） |
| retpoline | 間接分岐を`call`と`ret`に置き換えて、分岐予測器の悪用を防ぐ（Shadow Stackとは両立しない） |
| `lfence`、`CSDB`、`SB` | 投機的実行を止めるバリア命令 |
| プロセス分離 | 信頼できないコードを別プロセスで実行する（ブラウザのSite Isolation） |

信頼できない入力からネイティブコードを生成する処理系（JIT、WebAssemblyのAOTコンパイル、プラグインのサンドボックス化など）では、これらの対策も検討しましょう。
