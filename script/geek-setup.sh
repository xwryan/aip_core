#!/usr/bin/env bash
# geek-setup.sh — one-click manager for the geek bash config.
#   install    install CLI tools + write ~/.geekrc.sh + wire ~/.bashrc
#   disable    turn the config OFF (unwire ~/.bashrc, keep files & tools)
#   enable     turn it back ON
#   uninstall  unwire + remove ~/.geekrc.sh + apt-remove ONLY tools this script installed
#   status     show current state
set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}")"   # this script's real path (follows symlink)
SHORTCUT="$HOME/.local/bin/geek"
GEEKRC="$HOME/.geekrc.sh"
BASHRC="$HOME/.bashrc"
STATE_DIR="$HOME/.config/geek-setup"
STATE_PKGS="$STATE_DIR/installed.pkgs"
BEGIN="# >>> geek config >>>"
END="# <<< geek config <<<"
PKGS=(fzf bat fd-find eza zoxide)   # apt package names (binaries: batcat, fdfind)

log()  { printf '\033[38;5;42m[geek]\033[0m %s\n' "$*"; }
warn() { printf '\033[38;5;220m[geek]\033[0m %s\n' "$*"; }
err()  { printf '\033[38;5;203m[geek]\033[0m %s\n' "$*" >&2; }

backup_bashrc() {
  [ -f "$BASHRC" ] || return 0
  local b="$BASHRC.bak.$(date +%Y%m%d_%H%M%S)"
  cp -a "$BASHRC" "$b" && log "backed up bashrc -> $b"
}

# ---- write the config file -------------------------------------------------
write_geekrc() {
  cat > "$GEEKRC" <<'GEEKEOF'
# ~/.geekrc.sh — geek bash config (managed by geek-setup.sh).
# Tool-adaptive: uses fzf/bat/fd/eza/zoxide if present, degrades gracefully.
case $- in *i*) ;; *) return ;; esac

# ---- History: big, deduped, timestamped, shared ----
export HISTSIZE=100000
export HISTFILESIZE=200000
export HISTCONTROL=ignoreboth:erasedups
export HISTTIMEFORMAT='%F %T  '
export HISTIGNORE='ls:ll:la:cd:pwd:clear:c:exit:history:bg:fg:h'
shopt -s histappend histverify cmdhist
PROMPT_COMMAND='history -a; history -n'"${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

# ---- shopt: quality-of-life ----
shopt -s autocd 2>/dev/null
shopt -s cdspell dirspell 2>/dev/null
shopt -s direxpand 2>/dev/null
shopt -s checkwinsize globstar nocaseglob no_empty_cmd_completion 2>/dev/null

# ---- Keys: prefix + Up/Down = history search ----
bind '"\e[A": history-search-backward' 2>/dev/null
bind '"\e[B": history-search-forward'  2>/dev/null
bind 'set completion-ignore-case on'   2>/dev/null
bind 'set show-all-if-ambiguous on'    2>/dev/null
bind 'set colored-stats on'            2>/dev/null

# ---- Colors: ls, grep, man, less ----
command -v dircolors >/dev/null && eval "$(dircolors -b)"
export GREP_COLORS='mt=1;38;5;220'
export LESS='-R'
export LESS_TERMCAP_mb=$'\e[1;31m'   LESS_TERMCAP_md=$'\e[1;38;5;74m'
export LESS_TERMCAP_me=$'\e[0m'      LESS_TERMCAP_se=$'\e[0m'
export LESS_TERMCAP_so=$'\e[38;5;246;48;5;236m' LESS_TERMCAP_ue=$'\e[0m'
export LESS_TERMCAP_us=$'\e[1;38;5;146m'

# ---- PATH: user bins first (idempotent) ----
for d in "$HOME/.local/bin" "$HOME/bin"; do
  [ -d "$d" ] && [[ ":$PATH:" != *":$d:"* ]] && PATH="$d:$PATH"
done
export PATH

# ---- Aliases: listing (eza > ls), safety, shortcuts ----
if command -v eza >/dev/null; then
  alias ls='eza --group-directories-first --icons=auto'
  alias ll='eza -lh --group-directories-first --icons=auto --git'
  alias la='eza -lah --group-directories-first --icons=auto --git'
  alias lt='eza --tree --level=2 --icons=auto'
else
  alias ls='ls --color=auto --group-directories-first'
  alias ll='ls -lh --color=auto --group-directories-first'
  alias la='ls -lAh --color=auto --group-directories-first'
  alias lt='ls -R'
fi
alias l='ll'
alias grep='grep --color=auto'; alias egrep='egrep --color=auto'; alias fgrep='fgrep --color=auto'
alias diff='diff --color=auto'; alias ip='ip -color=auto'
alias rm='rm -I --preserve-root'; alias cp='cp -i'; alias mv='mv -i'; alias mkdir='mkdir -pv'; alias ln='ln -i'
alias ..='cd ..'; alias ...='cd ../..'; alias ....='cd ../../..'; alias -- -='cd -'
alias df='df -h'; alias du='du -h'; alias free='free -h'; alias h='history'; alias c='clear'
alias path='echo -e ${PATH//:/\\n}'
alias reload='source ~/.bashrc && echo "bash reloaded"'
alias please='sudo $(fc -ln -1)'
alias ports='ss -tulpn'; alias myip='curl -s https://ifconfig.me; echo'; alias now='date +"%F %T"'
command -v bat    >/dev/null && alias cat='bat --paging=never'
command -v batcat >/dev/null && alias cat='batcat --paging=never' && alias bat='batcat'
command -v fdfind >/dev/null && alias fd='fdfind'

# ---- git shortcuts ----
alias gs='git status -sb'; alias gd='git diff'; alias gds='git diff --staged'
alias ga='git add'; alias gc='git commit'; alias gca='git commit -a'
alias gp='git push'; alias gl='git pull'; alias gco='git checkout'; alias gb='git branch'
alias glog="git log --oneline --graph --decorate --all -20"

# ---- functions ----
mkcd() { mkdir -p -- "$1" && cd -- "$1"; }
up()   { local n=${1:-1}; local p=; while ((n-->0)); do p+=../; done; cd "$p" || return; }
bak()  { cp -a -- "$1" "$1.$(date +%Y%m%d_%H%M%S).bak"; }
ftext(){ command -v rg >/dev/null && rg -n --hidden -S "$@" || grep -rniI "$@" .; }
serve(){ python3 -m http.server "${1:-8000}"; }
extract() {
  [ -f "$1" ] || { echo "extract: '$1' not a file"; return 1; }
  case "$1" in
    *.tar.bz2|*.tbz2) tar xjf "$1" ;;  *.tar.gz|*.tgz) tar xzf "$1" ;;
    *.tar.xz)         tar xJf "$1" ;;  *.tar)          tar xf  "$1" ;;
    *.bz2)            bunzip2 "$1" ;;  *.gz)           gunzip  "$1" ;;
    *.zip)            unzip   "$1" ;;  *.rar)          unrar x "$1" ;;
    *.7z)             7z x    "$1" ;;  *.Z)            uncompress "$1" ;;
    *) echo "extract: unknown format '$1'" ;;
  esac
}

# ---- optional tools: activate only if installed ----
if command -v fzf >/dev/null; then
  command -v fd     >/dev/null && export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
  command -v fdfind >/dev/null && export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --exclude .git'
  export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border --info=inline'
  [ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && source /usr/share/doc/fzf/examples/key-bindings.bash
  [ -f /usr/share/doc/fzf/examples/completion.bash ]   && source /usr/share/doc/fzf/examples/completion.bash
fi
command -v zoxide >/dev/null && eval "$(zoxide init bash)" && alias cd='z'

# ---- prompt: two-line, exit-code aware, git-branch, venv ----
[ -f /usr/lib/git-core/git-sh-prompt ] && source /usr/lib/git-core/git-sh-prompt
export GIT_PS1_SHOWDIRTYSTATE=1 GIT_PS1_SHOWSTASHSTATE=1 \
       GIT_PS1_SHOWUNTRACKEDFILES=1 GIT_PS1_SHOWUPSTREAM=auto
__geek_ps1() {
  local ec=$?
  local R=$'\e[0m' DIM=$'\e[2m' CY=$'\e[38;5;44m' BL=$'\e[38;5;69m'
  local MG=$'\e[38;5;170m' GN=$'\e[38;5;42m' RD=$'\e[38;5;203m' YL=$'\e[38;5;220m'
  local host_c=$CY; [ -n "${SSH_CONNECTION:-}" ] && host_c=$YL
  local git=''; declare -f __git_ps1 >/dev/null && git="$(__git_ps1 " ${MG}(%s)${R}")"
  local venv=''; [ -n "${VIRTUAL_ENV:-}" ] && venv=" ${GN}(venv:$(basename "$VIRTUAL_ENV"))${R}"
  local ecs=''; [ "$ec" -ne 0 ] && ecs=" ${RD}✘$ec${R}"
  local mark=$GN; [ "$ec" -ne 0 ] && mark=$RD
  PS1="\n${DIM}┌─${R}[${host_c}\u@\h${R}]─[${BL}\w${R}]${git}${venv}${ecs}\n${DIM}└─${R}${mark}❯${R} "
}
PROMPT_COMMAND='__geek_ps1'"${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
case "$TERM" in xterm*|rxvt*|screen*|tmux*) PS1="\[\e]0;\u@\h: \w\a\]$PS1";; esac
GEEKEOF
  log "wrote $GEEKRC"
}

# ---- bashrc wiring ---------------------------------------------------------
clean_bashrc() {   # remove marker block + any legacy lines
  [ -f "$BASHRC" ] || return 0
  sed -i "/^${BEGIN}$/,/^${END}$/d" "$BASHRC"
  sed -i '/\.geekrc\.sh/d; /^# geek config$/d' "$BASHRC"
}
wire_bashrc() {
  backup_bashrc; clean_bashrc
  printf '\n%s\n[ -f "$HOME/.geekrc.sh" ] && source "$HOME/.geekrc.sh"\n%s\n' "$BEGIN" "$END" >> "$BASHRC"
  log "wired source line into $BASHRC"
}

# ---- shortcut: ~/.local/bin/geek -> this script -----------------------------
link_shortcut() {
  mkdir -p "$(dirname "$SHORTCUT")"
  ln -sf "$SELF" "$SHORTCUT" && log "shortcut: $SHORTCUT -> $SELF"
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "note: ~/.local/bin not on PATH in this shell; new bash (geekrc) adds it";; esac
}
unlink_shortcut() {
  # remove only if it points at this script (don't clobber a user's own 'geek')
  if [ -L "$SHORTCUT" ] && [ "$(readlink -f "$SHORTCUT")" = "$SELF" ]; then
    rm -f "$SHORTCUT" && log "removed shortcut $SHORTCUT"
  fi
}

# ---- tools -----------------------------------------------------------------
need_sudo() { if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; else SUDO=""; fi; }
install_tools() {
  command -v apt-get >/dev/null || { warn "no apt-get; skip tool install"; return 0; }
  need_sudo; mkdir -p "$STATE_DIR"; touch "$STATE_PKGS"
  log "apt-get update ..."; $SUDO apt-get update -qq || warn "apt update had warnings"
  local p
  for p in "${PKGS[@]}"; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed"; then
      log "$p already installed (won't remove on uninstall)"; continue
    fi
    if $SUDO apt-get install -y -qq "$p" >/dev/null 2>&1; then
      grep -qxF "$p" "$STATE_PKGS" || echo "$p" >> "$STATE_PKGS"
      log "installed $p"
    else
      warn "could not install $p (not in repo?) — skipped"
    fi
  done
}
remove_tools() {
  [ -f "$STATE_PKGS" ] || { log "no tools recorded as installed by this script"; return 0; }
  need_sudo
  local pk=(); mapfile -t pk < "$STATE_PKGS"
  [ ${#pk[@]} -eq 0 ] && { log "nothing to remove"; return 0; }
  log "apt remove: ${pk[*]}"
  $SUDO apt-get remove -y -qq "${pk[@]}" >/dev/null 2>&1 && log "removed" || warn "some removes failed"
  $SUDO apt-get autoremove -y -qq >/dev/null 2>&1 || true
  : > "$STATE_PKGS"
}

# ---- commands --------------------------------------------------------------
cmd_install()  { install_tools; write_geekrc; wire_bashrc; link_shortcut
                 log "DONE. Apply now:  source ~/.bashrc   (or open a new bash)"; }
cmd_enable()   { [ -f "$GEEKRC" ] || write_geekrc; wire_bashrc; log "config ON. source ~/.bashrc"; }
cmd_disable()  { backup_bashrc; clean_bashrc; log "config OFF (files & tools kept). Open new shell / source ~/.bashrc"; }
cmd_uninstall(){ backup_bashrc; clean_bashrc; rm -f "$GEEKRC" && log "removed $GEEKRC"; unlink_shortcut; remove_tools
                 log "DONE. Open a new shell for a clean bash."; }
cmd_status()   {
  printf 'geekrc file : %s\n' "$([ -f "$GEEKRC" ] && echo present || echo absent)"
  printf 'bashrc wired: %s\n' "$(grep -q '\.geekrc\.sh' "$BASHRC" 2>/dev/null && echo yes || echo no)"
  printf 'shortcut    : %s\n' "$([ -L "$SHORTCUT" ] && echo "$SHORTCUT -> $(readlink -f "$SHORTCUT")" || echo absent)"
  printf 'installed by this script: %s\n' "$([ -s "$STATE_PKGS" ] && tr '\n' ' ' < "$STATE_PKGS" || echo none)"
  local t; for t in fzf bat batcat fd fdfind eza zoxide rg git; do
    command -v "$t" >/dev/null && printf '  %-8s %s\n' "$t" "$(command -v "$t")"; done
}

cmd_help() {
  local H=$'\033[1;38;5;44m' A=$'\033[38;5;220m' R=$'\033[0m' D=$'\033[2m'
  cat <<EOF
${H}== geek 配置速查 ==${R}  ${D}(全部在新 bash 窗生效)${R}

${H}新工具${R}
  ${A}eza${R}    现代 ls(彩色/图标/git)   ll ${D}详情${R}  la ${D}含隐藏${R}  lt ${D}树状2层${R}
  ${A}bat${R}    彩色高亮 cat             cat FILE   ${D}(自动替 cat;裸命令 batcat)${R}
  ${A}fd${R}     极速 find                fd 名字    fd -e py   ${D}(裸命令 fdfind)${R}
  ${A}rg${R}     极速 grep(ripgrep)       rg 关键词   rg -n 'foo' src/
  ${A}fzf${R}    模糊搜索                 ${A}Ctrl-R${R} 搜历史  ${A}Ctrl-T${R} 选文件  ${A}Alt-C${R} 跳目录   cmd | fzf
  ${A}zoxide${R} 智能跳目录(cd 换成 z)    z 部分名   ${D}越常去越优先${R}   zi ${D}交互选${R}

${H}别名${R}
  ${A}导航${R}  ..  ...  ....   ${D}(上1/2/3级)${R}   -  ${D}回上个目录${R}
  ${A}git${R}   gs ${D}状态${R}  gd ${D}diff${R}  gds ${D}staged${R}  ga  gc  gca  gp  gl  gco  gb  glog ${D}图形日志${R}
  ${A}系统${R}  df du free ${D}带-h${R}   ports ${D}监听端口${R}   myip ${D}公网IP${R}   now ${D}时间戳${R}   path ${D}逐行PATH${R}
  ${A}其他${R}  please ${D}sudo 上条命令${R}   reload ${D}重载bashrc${R}   c ${D}clear${R}  h ${D}history${R}
  ${A}安全${R}  rm/cp/mv 带确认   mkdir -pv

${H}函数${R}
  ${A}mkcd${R} DIR      建目录并进入
  ${A}up${R} N          上跳 N 级 (up 3 = cd ../../..)
  ${A}bak${R} FILE      建带时间戳备份 FILE.YYYYmmdd_HHMMSS.bak
  ${A}ftext${R} PATTERN 全目录搜文本(rg 优先)
  ${A}serve${R} [PORT]  当前目录起 http 服务(默认8000)
  ${A}extract${R} FILE  万能解包(tar/gz/zip/7z/rar…)

${H}快捷键 / 提示符${R}
  输前缀 + ${A}↑/↓${R}   按前缀搜历史        Tab 补全大小写不敏感
  提示符两行:  ┌─[user@host]─[路径] (git分支*脏标) (venv) ${A}✘退出码${R}
              └─❯   ${D}(上条失败 ❯ 变红)${R}

${D}管理命令: geek {install|enable|disable|uninstall|status|help}${R}
EOF
}

case "${1:-}" in
  install)   cmd_install ;;
  enable)    cmd_enable ;;
  disable)   cmd_disable ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  help|-h|--help) cmd_help ;;
  *) cat <<USAGE
geek-setup.sh — geek bash config manager
  install     install tools (fzf bat fd-find eza zoxide) + write ~/.geekrc.sh + wire ~/.bashrc
  disable     turn config OFF (unwire ~/.bashrc; keep files & tools)
  enable      turn config back ON
  uninstall   unwire + delete ~/.geekrc.sh + apt-remove ONLY tools this script installed
  status      show current state
  help        show tool/alias/function cheatsheet (工具用法速查)
USAGE
  ;;
esac
