#!/bin/bash
# MacCheckup: a read-only, beginner-friendly macOS health snapshot.
# Compatible with the Bash 3.2 shipped with macOS.

set -u
VERSION="0.1.0"

usage() {
  cat <<'USAGE'
MacCheckup - macOS の基本状態を確認して、Markdown レポートを表示します。

使い方:
  ./maccheckup.sh [オプション]

オプション:
  -h, --help       このヘルプを表示
  -v, --version    バージョンを表示

安全性:
  - 読み取り専用です。設定変更・削除・修復は行いません。
  - sudo、ネットワーク通信、外部APIは使用しません。
  - レポートをファイルに保存する場合は、出力をリダイレクトしてください。
USAGE
}

case "${1-}" in
  -h|--help) usage; exit 0 ;;
  -v|--version) printf 'MacCheckup %s\n' "$VERSION"; exit 0 ;;
  "") ;;
  *) printf '不明なオプション: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
esac

# Return a simple status label for Markdown output.
status_label() {
  case "$1" in
    normal) printf '正常' ;;
    caution) printf '注意' ;;
    check) printf '要確認' ;;
    unknown) printf '判定不可' ;;
    *) printf '判定不可' ;;
  esac
}

# Keep all command failures non-fatal: partial results are still useful.
get_value() {
  # Usage: get_value command args... ; prints a value or an empty string.
  "$@" 2>/dev/null || true
}

OS_NAME="$(get_value sw_vers -productName)"
OS_VERSION="$(get_value sw_vers -productVersion)"
OS_BUILD="$(get_value sw_vers -buildVersion)"
ARCH="$(get_value uname -m)"
MODEL="$(get_value sysctl -n hw.model)"

if [ -z "$OS_NAME" ]; then OS_NAME="macOS (取得できません)"; fi
if [ -z "$OS_VERSION" ]; then OS_VERSION="取得できません"; fi
if [ -z "$OS_BUILD" ]; then OS_BUILD="取得できません"; fi
if [ -z "$ARCH" ]; then ARCH="取得できません"; fi
if [ -z "$MODEL" ]; then MODEL="取得できません"; fi

# Disk: use the POSIX-style output and parse numeric fields, not localized labels.
DISK_LINE="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}')"
DISK_TOTAL=""
DISK_USED=""
DISK_AVAIL=""
DISK_PERCENT=""
if [ -n "$DISK_LINE" ]; then
  read -r DISK_TOTAL DISK_USED DISK_AVAIL DISK_PERCENT <<EOF_DISK
$DISK_LINE
EOF_DISK
fi

DISK_STATUS="unknown"
DISK_NOTE="ディスク容量を取得できませんでした。"
if [ -n "$DISK_AVAIL" ] && [ -n "$DISK_TOTAL" ] && [ "$DISK_TOTAL" -gt 0 ] 2>/dev/null; then
  DISK_FREE_PCT=$(( DISK_AVAIL * 100 / DISK_TOTAL ))
  DISK_FREE_GB=$(( DISK_AVAIL / 1024 / 1024 ))
  if [ "$DISK_FREE_PCT" -lt 10 ]; then
    DISK_STATUS="check"
    DISK_NOTE="空き容量が少なくなっています。不要なファイルを削除する前に、必要なデータをバックアップしてください。"
  elif [ "$DISK_FREE_PCT" -lt 20 ]; then
    DISK_STATUS="caution"
    DISK_NOTE="空き容量に余裕が少なめです。大きなファイルや空き容量の推移を確認してください。"
  else
    DISK_STATUS="normal"
    DISK_NOTE="現時点では空き容量に大きな問題は見つかりませんでした。"
  fi
  DISK_SUMMARY="空き ${DISK_FREE_GB} GiB / 使用率 ${DISK_PERCENT}"
  else
  DISK_SUMMARY="取得できませんでした"
fi

# Memory: memory_pressure's free percentage is an estimate, not a direct health diagnosis.
MEMORY_FREE_PCT=""
MEMORY_OUTPUT="$(get_value memory_pressure -Q)"
if [ -n "$MEMORY_OUTPUT" ]; then
  MEMORY_FREE_PCT="$(printf '%s\n' "$MEMORY_OUTPUT" | sed -n 's/.*System-wide memory free percentage: *\([0-9][0-9]*\)%.*/\1/p' | head -n 1)"
fi
MEMORY_STATUS="unknown"
MEMORY_NOTE="メモリ状態を判定できませんでした。アクティビティモニタの「メモリ」タブも確認してください。"
if [ -n "$MEMORY_FREE_PCT" ]; then
  if [ "$MEMORY_FREE_PCT" -lt 10 ]; then
    MEMORY_STATUS="caution"
    MEMORY_NOTE="利用可能なメモリが少なめです。動作が重い場合は、アクティビティモニタでメモリプレッシャーを確認してください。"
  else
    MEMORY_STATUS="normal"
    MEMORY_NOTE="この1回の測定では、利用可能メモリが極端に少ない状態ではありません。"
  fi
  MEMORY_SUMMARY="利用可能メモリの目安: ${MEMORY_FREE_PCT}%"
else
  MEMORY_SUMMARY="取得できませんでした"
fi

# Battery: report only the percentage/state if present; desktop Macs may have no battery.
BATTERY_OUTPUT="$(get_value pmset -g batt)"
BATTERY_SUMMARY="バッテリー情報がありません（デスクトップMacでは通常の状態です）"
BATTERY_STATUS="unknown"
if printf '%s\n' "$BATTERY_OUTPUT" | grep -q 'InternalBattery'; then
  # Extract the complete percentage token (e.g. 94%), not just its last digit.
  # Restrict parsing to the InternalBattery line to avoid unrelated numbers.
  BATTERY_LINE="$(printf '%s\n' "$BATTERY_OUTPUT" | grep 'InternalBattery' | head -n 1)"
  BATTERY_PCT="$(printf '%s\n' "$BATTERY_LINE" | grep -Eo '[0-9]{1,3}%' | head -n 1 | tr -d '%')"
  BATTERY_STATE="$(printf '%s\n' "$BATTERY_LINE" | sed -n 's/.*; *\([^;]*\); *$/\1/p')"
  if [ -n "$BATTERY_PCT" ]; then
    BATTERY_SUMMARY="${BATTERY_PCT}%${BATTERY_STATE:+（${BATTERY_STATE}）}"
    if [ "$BATTERY_PCT" -lt 15 ] 2>/dev/null; then
      BATTERY_STATUS="caution"
    else
      BATTERY_STATUS="normal"
    fi
  else
    BATTERY_SUMMARY="バッテリーは検出されましたが、残量を読み取れませんでした"
  fi
fi

CHECK_DATE="$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date)"

cat <<EOF_REPORT
# MacCheckup レポート

- **確認日時:** ${CHECK_DATE}
- **総合判定:** 初期版では総合判定を行いません（項目別の目安です）

## Macの基本情報

| 項目 | 結果 |
|---|---|
| OS | ${OS_NAME} ${OS_VERSION} (build ${OS_BUILD}) |
| CPUアーキテクチャ | ${ARCH} |
| モデル識別子 | ${MODEL} |

## チェック結果

| 項目 | 判定 | 結果 |
|---|---|---|
| 起動ディスク | $(status_label "$DISK_STATUS") | ${DISK_SUMMARY} |
| メモリ | $(status_label "$MEMORY_STATUS") | ${MEMORY_SUMMARY} |
| バッテリー | $(status_label "$BATTERY_STATUS") | ${BATTERY_SUMMARY} |

## やさしい解説

- **起動ディスク:** ${DISK_NOTE}
- **メモリ:** ${MEMORY_NOTE}
- **バッテリー:** $(if [ "$BATTERY_STATUS" = "caution" ]; then printf '残量が少なめです。可能なら電源に接続してください。'; elif [ "$BATTERY_STATUS" = "normal" ]; then printf '残量の表示を取得できました。残量だけではバッテリーの劣化度は判断できません。'; else printf 'バッテリーの有無や状態を十分に判定できないため、必要に応じてシステム設定で確認してください。'; fi)

## 注意事項

- このレポートは基本的な情報をまとめたもので、故障を確定診断するものではありません。
- メモリの値は測定時点の目安です。スワップ使用量だけで異常とは判定しません。
- バッテリーの劣化度・最大容量は、この初期版では診断していません。
- このスクリプトは読み取り専用で、設定変更・ファイル削除・修復・ネットワーク通信を行いません。
- レポートを公開・共有する前に、内容を確認してください。
EOF_REPORT
