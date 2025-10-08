# アプリのビルドと実行方法 - 詳細ガイド

## 🎯 Xcodeでのビルドと実行（推奨）

### 方法1: Xcodeから直接実行

1. **Xcodeでプロジェクトを開く**
   ```bash
   open "Amazon Bedrock Client for Mac.xcodeproj"
   ```

2. **ビルドして実行**
   - `⌘ + R` キーを押す
   - または、メニューから `Product` → `Run`
   - または、ツールバーの ▶️ ボタンをクリック

3. **デバッグモードで起動**
   - Xcodeのコンソールでログを確認しながら実行できます
   - ブレークポイントを設定してデバッグも可能

### 方法2: ビルド後のアプリを直接実行

1. **プロジェクトをビルド**
   ```bash
   cd "/Users/a15109/git/amazon-bedrock-client-for-mac"
   xcodebuild -project "Amazon Bedrock Client for Mac.xcodeproj" \
     -scheme "Amazon Bedrock Client for Mac" \
     -configuration Debug build
   ```

2. **ビルドされたアプリを実行**
   ```bash
   open "/Users/a15109/Library/Developer/Xcode/DerivedData/Amazon_Bedrock_Client_for_Mac-fqtfnspsqnjfaldwvindenvtmzkz/Build/Products/Debug/Amazon Bedrock Debug.app"
   ```

3. **または、Finderから実行**
   - Finderで以下のパスを開く:
     ```
     /Users/a15109/Library/Developer/Xcode/DerivedData/Amazon_Bedrock_Client_for_Mac-fqtfnspsqnjfaldwvindenvtmzkz/Build/Products/Debug/
     ```
   - `Amazon Bedrock Debug.app` をダブルクリック

## 🚀 Releaseビルドの作成（配布用）

### 方法1: build.shスクリプトを使用

```bash
cd "/Users/a15109/git/amazon-bedrock-client-for-mac"
./build.sh
```

### 方法2: xcodebuildコマンド

```bash
xcodebuild -project "Amazon Bedrock Client for Mac.xcodeproj" \
  -scheme "Amazon Bedrock Client for Mac" \
  -configuration Release \
  -derivedDataPath ./build \
  clean build
```

生成されたアプリ:
```
./build/Build/Products/Release/Amazon Bedrock.app
```

## 📦 アプリのインストール

### Applicationsフォルダにコピー

```bash
# Releaseビルド後
cp -R "./build/Build/Products/Release/Amazon Bedrock.app" /Applications/

# または、ビルドスクリプト使用後
open /Applications/
# Finderで `Amazon Bedrock.app` をドラッグ&ドロップ
```

## 🔧 現在のビルド状況

### ビルド済みアプリの場所

**Debugビルド**:
```
/Users/a15109/Library/Developer/Xcode/DerivedData/Amazon_Bedrock_Client_for_Mac-fqtfnspsqnjfaldwvindenvtmzkz/Build/Products/Debug/Amazon Bedrock Debug.app
```

**実行中のプロセス確認**:
```bash
ps aux | grep "Amazon Bedrock" | grep -v grep
```

現在2つのプロセスが実行中:
1. `/Applications/Amazon Bedrock Debug.app` - インストール済みのバージョン
2. `/Users/a15109/Library/.../Debug/Amazon Bedrock Debug.app` - 今ビルドしたバージョン

## 🛠 トラブルシューティング

### ビルドしたアプリが0バイトに見える

これは通常、macOSのアプリバンドルの表示方法の問題です。実際には：

```bash
# アプリバンドル全体のサイズ
du -sh "/path/to/Amazon Bedrock Debug.app"

# 実行ファイル本体のサイズ
ls -lh "/path/to/Amazon Bedrock Debug.app/Contents/MacOS/Amazon Bedrock Debug"
```

現在の状況:
- 実行ファイル: **57KB** （正常）
- プロセス実行中: **正常に動作中**

### 複数のバージョンが起動している

```bash
# すべて終了
pkill -f "Amazon Bedrock"

# 再度Xcodeから実行
```

### DerivedDataの場所が変わる

XcodeのDerivedDataフォルダのハッシュ部分が変わることがあります:

```bash
# DerivedDataフォルダを探す
find ~/Library/Developer/Xcode/DerivedData -name "Amazon Bedrock Debug.app" -type d 2>/dev/null | head -1
```

## ⚡️ クイックスタート

### 最も簡単な方法

1. Xcodeでプロジェクトを開く
   ```bash
   cd "/Users/a15109/git/amazon-bedrock-client-for-mac"
   open "Amazon Bedrock Client for Mac.xcodeproj"
   ```

2. `⌘ + R` を押す

3. アプリが起動します

## 📝 開発ワークフロー

### 日常的な開発

1. **Xcodeでコード編集**
2. **⌘ + R で実行**（自動的にビルド→実行）
3. **コンソールでログ確認**
4. **変更→実行を繰り返し**

### Releaseビルド作成

1. **build.shを実行**
   ```bash
   ./build.sh
   ```

2. **生成されたアプリを確認**
   ```bash
   open ./build/Build/Products/Release/
   ```

3. **Applicationsにコピー**
   ```bash
   cp -R "./build/Build/Products/Release/Amazon Bedrock.app" /Applications/
   ```

## 🎉 確認: アプリは正常に動作中

現在の状況:
- ✅ ビルド成功
- ✅ 実行ファイル生成 (57KB)
- ✅ アプリ起動中
- ✅ プロセス実行中

ビルドされたアプリは正常に動作しています！
