#!/usr/bin/env bash
# assume.sh  ―  cross-account や MFA 用の一時クレデンシャルを取得して export する
#
# 使い方） source ./assume.sh [role-arn] [session-name] [mfa-arn] [profile]
#   引数はすべて任意。実行すると role-arn → session-name → mfa-arn → profile の順に
#   対話的に尋ねる。引数を渡した項目は [既定値] として表示され、Enter で確定できる。
#   例）  source ./assume.sh                                   # 全部プロンプトで入力
#        source ./assume.sh arn:aws:iam::999999999999:role/Admin cli-demo
#
# jq と AWS CLI が入っている前提

set -o pipefail

# このスクリプトは取得したクレデンシャルを呼び出し元シェルへ export する設計のため
# source して使う前提。直接実行（./assume.sh）すると別プロセスになり export が消える上、
# 各所の `return` がエラーになって処理が止まらず誤動作するので、ここで明示的に弾く。
if [[ -n "${ZSH_VERSION:-}" ]]; then
    case "${ZSH_EVAL_CONTEXT:-}" in
        *:file) _sourced=1 ;;   # source されたとき末尾が :file になる
        *)      _sourced=0 ;;
    esac
else
    [[ "${BASH_SOURCE[0]}" != "$0" ]] && _sourced=1 || _sourced=0
fi
if [[ "$_sourced" -ne 1 ]]; then
    echo "このスクリプトは source して使ってください（export を現在のシェルへ反映するため）:" >&2
    echo "  source ./assume.sh <role-arn> <session-name> [mfa-serial] [profile]" >&2
    exit 1
fi
unset _sourced

# 引数があれば既定値として使い、実行後に対話的に確認・入力する。
# （長い ARN を毎回打たなくてよいよう、プロンプトで順に尋ねる形。
#   引数を渡した項目は [既定値] が表示され、Enter で確定できる）
DEF_ROLE_ARN="${1:-}"
DEF_SESSION="${2:-}"
DEF_MFA_ARN="${3:-}"
DEF_PROFILE="${4:-}"
DURATION=3600             # 1 時間

# プロンプトを少し見やすくする色設定（stderr が端末のときだけ色を付ける）。
if [[ -t 2 ]]; then
    _C_TITLE=$'\033[1;36m'   # 太字シアン（見出し）
    _C_LABEL=$'\033[1m'      # 太字（項目名）
    _C_HINT=$'\033[2m'       # 薄色（説明・例）
    _C_ERR=$'\033[0;31m'     # 赤（エラー）
    _C_OFF=$'\033[0m'
else
    _C_TITLE='' _C_LABEL='' _C_HINT='' _C_ERR='' _C_OFF=''
fi

echo "${_C_TITLE}=== AssumeRole: 一時クレデンシャルの取得 ===${_C_OFF}" >&2
echo "${_C_HINT}各項目を入力してください。[…] は既定値で、空欄のまま Enter すると確定します。${_C_OFF}" >&2
echo >&2

# 説明・項目名・既定値を表示して 1 行読む小ヘルパー（bash/zsh 両対応のため echo+read で実装）。
# 引数: $1=項目名, $2=説明/例（任意）, $3=既定値（任意）
# プロンプトは stderr、入力は /dev/tty、値は stdout に返すので $(...) で受けられる。
_assume_ask() {
    local _label="$1" _hint="$2" _def="$3" _ans
    [[ -n "$_hint" ]] && echo "  ${_C_HINT}${_hint}${_C_OFF}" >&2
    if [[ -n "$_def" ]]; then
        echo -n "${_C_LABEL}${_label}${_C_OFF} [${_def}]: " >&2
    else
        echo -n "${_C_LABEL}${_label}${_C_OFF}: " >&2
    fi
    read -r _ans </dev/tty
    printf '%s' "${_ans:-$_def}"
}

# role-arn（必須）: 空のうちは聞き直す
_H_ROLE="引き受けるロールの ARN  例) arn:aws:iam::123456789012:role/Admin"
ROLE_ARN=$(_assume_ask "ロール ARN" "$_H_ROLE" "$DEF_ROLE_ARN")
while [[ -z "$ROLE_ARN" ]]; do
    echo "${_C_ERR}✗ ロール ARN は必須です。もう一度入力してください。${_C_OFF}" >&2
    ROLE_ARN=$(_assume_ask "ロール ARN" "$_H_ROLE" "$DEF_ROLE_ARN")
done

# session-name（必須）: 2〜64 文字・使用可能文字 [A-Za-z0-9+=,.@_-] のみ
_H_SESSION="2〜64文字 [A-Za-z0-9+=,.@_-]・CloudTrail に記録されます  例) cli-demo, alice-deploy"
SESSION=$(_assume_ask "セッション名" "$_H_SESSION" "$DEF_SESSION")
while [[ ! "$SESSION" =~ ^[A-Za-z0-9+=,.@_-]{2,64}$ ]]; do
    echo "${_C_ERR}✗ セッション名は 2〜64文字で、使える文字は [A-Za-z0-9+=,.@_-] のみです。${_C_OFF}" >&2
    SESSION=$(_assume_ask "セッション名" "$_H_SESSION" "$DEF_SESSION")
done

# mfa-arn（任意）: Enter でスキップ＝MFA なし
_H_MFA="MFA を使う場合のみ。不要なら空のまま Enter  例) arn:aws:iam::123456789012:mfa/alice"
MFA_ARN=$(_assume_ask "MFA デバイス ARN（任意）" "$_H_MFA" "$DEF_MFA_ARN")

# profile（任意）: Enter でスキップ＝既定の資格情報を使用
_H_PROFILE="使う認証プロファイル名。既定でよければ空のまま Enter  例) default, dev"
PROFILE=$(_assume_ask "AWS プロファイル（任意）" "$_H_PROFILE" "$DEF_PROFILE")

unset -f _assume_ask
unset DEF_ROLE_ARN DEF_SESSION DEF_MFA_ARN DEF_PROFILE
unset _H_ROLE _H_SESSION _H_MFA _H_PROFILE
unset _C_TITLE _C_LABEL _C_HINT _C_ERR _C_OFF

# 入力内容のサマリ（確認用）
echo >&2
echo "以下の内容で AssumeRole します:" >&2
echo "  role-arn     = $ROLE_ARN" >&2
echo "  session-name = $SESSION" >&2
[[ -n "$MFA_ARN" ]] && echo "  mfa-arn      = $MFA_ARN" >&2
[[ -n "$PROFILE" ]] && echo "  profile      = $PROFILE" >&2

# MFA とプロファイルのオプションは配列で構築する。
# 文字列に詰めて未クォートで単語分割に頼ると、値に空白が混じった瞬間に壊れるため。
MFA_OPTIONS=()
if [[ -n "$MFA_ARN" ]]; then
    echo "MFA デバイスが指定されました。ワンタイムコードが必要です。" >&2
    echo -n "MFA ワンタイムコード（6桁）を入力: " >&2
    read -r MFA_CODE </dev/tty
    MFA_OPTIONS=(--serial-number "$MFA_ARN" --token-code "$MFA_CODE")
fi

# プロファイルはこの呼び出しにだけ効かせる（AWS_PROFILE を export しないことで
# シェルを汚さず、AssumeRole 失敗時にも設定を残さない）。
# さらに、前回 source した際の一時クレデンシャルが環境に残っていると
# --profile より優先されてプロファイルが無視されるため、この呼び出しに限り除外する。
PROFILE_OPTIONS=()
CREDS_ENV=()
if [[ -n "$PROFILE" ]]; then
    PROFILE_OPTIONS=(--profile "$PROFILE")
    CREDS_ENV=(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
                   -u AWS_SESSION_TOKEN -u AWS_EXPIRATION)
fi

JSON=$("${CREDS_ENV[@]}" aws sts assume-role \
        --role-arn "$ROLE_ARN"               \
        --role-session-name "$SESSION"       \
        --duration-seconds "$DURATION"       \
        "${MFA_OPTIONS[@]}"                  \
        "${PROFILE_OPTIONS[@]}"              \
        --output json)

if [[ $? -ne 0 ]]; then
    echo "AssumeRole に失敗しました。" >&2
    return 1
fi

# 取得したクレデンシャルを解析。export する前に妥当性を確認する
# （jq 未インストールや不正な JSON のとき、空文字や "null" を export しないため）。
_AKID=$(jq -r '.Credentials.AccessKeyId'     <<<"$JSON")
_SAK=$( jq -r '.Credentials.SecretAccessKey' <<<"$JSON")
_TOK=$( jq -r '.Credentials.SessionToken'    <<<"$JSON")
_EXP=$( jq -r '.Credentials.Expiration'      <<<"$JSON")   # ISO-8601

if [[ -z "$_AKID" || "$_AKID" == "null" ]]; then
    echo "クレデンシャルの解析に失敗しました（jq は入っていますか？）。" >&2
    unset JSON _AKID _SAK _TOK _EXP MFA_CODE
    return 1
fi

export AWS_ACCESS_KEY_ID="$_AKID"
export AWS_SECRET_ACCESS_KEY="$_SAK"
export AWS_SESSION_TOKEN="$_TOK"
export AWS_EXPIRATION="$_EXP"

# 秘密情報を含む一時変数をシェルに残さない
unset JSON _AKID _SAK _TOK _EXP MFA_CODE

echo "AssumeRole 成功。$AWS_EXPIRATION まで有効です。"
echo "確認）  aws sts get-caller-identity"
