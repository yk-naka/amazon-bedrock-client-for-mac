#!/bin/bash

# Amazon Bedrock Client for Mac - Build Script
# このスクリプトは以下の処理を自動化します：
# 1. 既存のアプリケーションプロセスを強制終了
# 2. プロジェクトをビルド（--cleanオプションでクリーンビルド）
# 3. 新しいアプリケーションを起動

set -e  # エラーが発生した場合にスクリプトを終了

# 色付きの出力用の定数
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# アプリケーション名とパス
APP_NAME="Amazon Bedrock Client for Mac"
PROJECT_NAME="Amazon Bedrock Client for Mac.xcodeproj"
SCHEME_NAME="Amazon Bedrock Client for Mac"
BUILD_DIR="build"
DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData"
WORKSPACE_PATH="$PWD/$PROJECT_NAME/project.xcworkspace"
CONFIGURATION="Debug"

# コマンドライン引数の処理
CLEAN_BUILD=false
HELP=false

for arg in "$@"; do
    case $arg in
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        --release)
            CONFIGURATION="Release"
            shift
            ;;
        --help|-h)
            HELP=true
            shift
            ;;
        *)
            echo -e "${RED}不明なオプション: $arg${NC}"
            echo -e "${YELLOW}使用方法: $0 [--clean] [--help]${NC}"
            exit 1
            ;;
    esac
done

# ヘルプ表示
if [ "$HELP" = true ]; then
    echo -e "${BLUE}=== Amazon Bedrock Client for Mac Build Script ===${NC}"
    echo ""
    echo -e "${YELLOW}使用方法:${NC}"
    echo -e "  $0                 通常ビルド（既存のビルドファイルを保持）"
    echo -e "  $0 --clean         クリーンビルド（全てのビルドファイルを削除してからビルド）"
    echo -e "  $0 --release       Release構成でビルド（デフォルトはDebug）"
    echo -e "  $0 --help          このヘルプを表示"
    echo ""
    echo -e "${YELLOW}説明:${NC}"
    echo -e "  通常ビルド: 既存のビルドファイルを活用して高速にビルドします"
    echo -e "  クリーンビルド: 全てのビルドファイルを削除してから完全にビルドし直します"
    echo ""
    exit 0
fi

echo -e "${BLUE}=== Amazon Bedrock Client for Mac Build Script ===${NC}"
echo -e "${BLUE}開始時刻: $(date)${NC}"
if [ "$CLEAN_BUILD" = true ]; then
    echo -e "${BLUE}モード: クリーンビルド${NC}"
else
    echo -e "${BLUE}モード: 通常ビルド${NC}"
fi
echo ""

# Step 1: 既存のアプリケーションプロセスを強制終了
echo -e "${YELLOW}Step 1: 既存のアプリケーションプロセスを確認・終了中...${NC}"
PIDS=$(pgrep -f "$APP_NAME" || true)
if [ -n "$PIDS" ]; then
    echo -e "${YELLOW}既存のプロセスを発見しました (PID: $PIDS)${NC}"
    echo "$PIDS" | xargs kill -9 2>/dev/null || true
    sleep 2
    echo -e "${GREEN}✓ アプリケーションプロセスを終了しました${NC}"
else
    echo -e "${GREEN}✓ 実行中のアプリケーションプロセスはありません${NC}"
fi
echo ""

# Step 2: クリーンビルドの場合のみ古いファイルを削除
if [ "$CLEAN_BUILD" = true ]; then
    echo -e "${YELLOW}Step 2: 古いアプリケーションファイルを削除中...${NC}"

    # Applications フォルダから削除
    if [ -d "/Applications/$APP_NAME.app" ]; then
        echo -e "${YELLOW}Applications フォルダからアプリを削除中...${NC}"
        rm -rf "/Applications/$APP_NAME.app"
        echo -e "${GREEN}✓ Applications フォルダから削除完了${NC}"
    fi

    # ビルドディレクトリを削除
    if [ -d "$BUILD_DIR" ]; then
        echo -e "${YELLOW}ビルドディレクトリを削除中...${NC}"
        rm -rf "$BUILD_DIR"
        echo -e "${GREEN}✓ ビルドディレクトリを削除完了${NC}"
    fi

    # DerivedData を削除（より徹底的なクリーン）
    echo -e "${YELLOW}DerivedData を削除中...${NC}"
    find "$DERIVED_DATA_PATH" -name "*Amazon_Bedrock_Client_for_Mac*" -type d -exec rm -rf {} + 2>/dev/null || true
    echo -e "${GREEN}✓ DerivedData を削除完了${NC}"
    echo ""
else
    echo -e "${YELLOW}Step 2: 通常ビルドのため、ビルドファイルを保持します${NC}"
    
    # 通常ビルドでもApplicationsフォルダの古いアプリは削除
    if [ -d "/Applications/$APP_NAME.app" ]; then
        echo -e "${YELLOW}Applications フォルダから古いアプリを削除中...${NC}"
        rm -rf "/Applications/$APP_NAME.app"
        echo -e "${GREEN}✓ Applications フォルダから削除完了${NC}"
    fi
    echo ""
fi

# Step 3: Xcode プロジェクトをビルド
if [ "$CLEAN_BUILD" = true ]; then
    echo -e "${YELLOW}Step 3: プロジェクトをクリーンビルド中...${NC}"
    
    # クリーンを実行
    echo -e "${YELLOW}プロジェクトをクリーン中...${NC}"
    xcodebuild clean \
        -workspace "$WORKSPACE_PATH" \
        -scheme "$SCHEME_NAME" \
        -configuration "$CONFIGURATION" \
        -UseModernBuildSystem=YES \
        -destination 'platform=macOS' \
        CODE_SIGNING_ALLOWED=NO \
        SWIFT_ENABLE_EXPLICIT_MODULES=NO
    
    echo -e "${GREEN}✓ プロジェクトクリーン完了${NC}"
else
    echo -e "${YELLOW}Step 3: プロジェクトを通常ビルド中...${NC}"
fi

# パッケージ依存関係を解決
echo -e "${YELLOW}パッケージ依存関係を解決中...${NC}"
xcodebuild -resolvePackageDependencies \
    -workspace "$WORKSPACE_PATH" \
    -scheme "$SCHEME_NAME" \
    -UseModernBuildSystem=YES

echo -e "${GREEN}✓ パッケージ依存関係解決完了${NC}"

# ビルドを実行（依存関係の問題を回避するため、複数回試行）
echo -e "${YELLOW}プロジェクトをビルド中...${NC}"

# 最初の試行
echo -e "${YELLOW}ビルド試行 1/3...${NC}"
if xcodebuild build \
    -workspace "$WORKSPACE_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -UseModernBuildSystem=YES \
    CODE_SIGNING_ALLOWED=NO \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO 2>/dev/null; then
    echo -e "${GREEN}✓ ビルド成功（1回目）${NC}"
else
    echo -e "${YELLOW}1回目のビルドが失敗しました。再試行中...${NC}"
    
    # 2回目の試行
    echo -e "${YELLOW}ビルド試行 2/3...${NC}"
    if xcodebuild build \
        -workspace "$WORKSPACE_PATH" \
        -scheme "$SCHEME_NAME" \
        -configuration "$CONFIGURATION" \
        -destination 'platform=macOS' \
        -UseModernBuildSystem=YES \
        CODE_SIGNING_ALLOWED=NO \
        -skipPackagePluginValidation \
        -skipMacroValidation \
        SWIFT_ENABLE_EXPLICIT_MODULES=NO 2>/dev/null; then
        echo -e "${GREEN}✓ ビルド成功（2回目）${NC}"
    else
        echo -e "${YELLOW}2回目のビルドが失敗しました。最終試行中...${NC}"
        
        # 3回目の試行（エラー出力を表示）
        echo -e "${YELLOW}ビルド試行 3/3...${NC}"
        xcodebuild build \
            -workspace "$WORKSPACE_PATH" \
            -scheme "$SCHEME_NAME" \
            -configuration "$CONFIGURATION" \
            -destination 'platform=macOS' \
            -UseModernBuildSystem=YES \
            CODE_SIGNING_ALLOWED=NO \
            -skipPackagePluginValidation \
            -skipMacroValidation \
            SWIFT_ENABLE_EXPLICIT_MODULES=NO
        
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ 3回の試行すべてでビルドが失敗しました${NC}"
            echo -e "${RED}これは依存関係の解決に関する既知の問題の可能性があります${NC}"
            echo -e "${YELLOW}解決方法: Xcodeでプロジェクトを開き、手動でビルドしてください${NC}"
            exit 1
        fi
    fi
fi

echo -e "${GREEN}✓ ビルド完了${NC}"
echo ""

# Step 4: ビルドされたアプリケーションを Applications フォルダにコピー
echo -e "${YELLOW}Step 4: アプリケーションを Applications フォルダにコピー中...${NC}"

# ビルドされたアプリのパスを探す（DerivedDataディレクトリから探す）
# より柔軟なパターンで検索（Amazon Bedrock Debug.app などの名前も対応）
BUILT_APP_PATH=$(find "$DERIVED_DATA_PATH" -name "*Amazon*Bedrock*.app" -type d 2>/dev/null | grep -E "(Debug|Release)" | head -1)

# もしDerivedDataで見つからない場合は、buildディレクトリからも探す
if [ -z "$BUILT_APP_PATH" ] && [ -d "$BUILD_DIR" ]; then
    BUILT_APP_PATH=$(find "$BUILD_DIR" -name "$APP_NAME.app" -type d | head -1)
fi

if [ -n "$BUILT_APP_PATH" ] && [ -d "$BUILT_APP_PATH" ]; then
    echo -e "${YELLOW}ビルドされたアプリを発見: $BUILT_APP_PATH${NC}"
    cp -R "$BUILT_APP_PATH" "/Applications/"
    echo -e "${GREEN}✓ Applications フォルダにコピー完了${NC}"
else
    echo -e "${RED}❌ ビルドされたアプリケーションが見つかりません${NC}"
    echo -e "${YELLOW}DerivedDataディレクトリの内容を確認中...${NC}"
    find "$DERIVED_DATA_PATH" -name "*.app" -type d 2>/dev/null | head -5
    echo -e "${RED}ビルドが失敗した可能性があります${NC}"
    exit 1
fi
echo ""

# Step 5: 新しいアプリケーションを起動
echo -e "${YELLOW}Step 5: 新しいアプリケーションを起動中...${NC}"
sleep 2  # ファイルシステムの同期を待つ

# コピーしたアプリの実際の名前を取得
COPIED_APP_NAME=$(basename "$BUILT_APP_PATH")
COPIED_APP_PATH="/Applications/$COPIED_APP_NAME"

if [ -d "$COPIED_APP_PATH" ]; then
    open "$COPIED_APP_PATH"
    echo -e "${GREEN}✓ アプリケーションを起動しました: $COPIED_APP_NAME${NC}"
else
    echo -e "${RED}❌ アプリケーションファイルが見つかりません: $COPIED_APP_PATH${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}=== ビルドプロセス完了 ===${NC}"
echo -e "${GREEN}完了時刻: $(date)${NC}"
echo -e "${GREEN}Amazon Bedrock Client for Mac が正常にビルド・起動されました！${NC}"
