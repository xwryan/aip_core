"""script/tests：离线刷新回归；仅持有临时rc/备份，不改HOME或真实shell配置。

真实PTY屏幕重绘由独立验收执行；此处固定refresh所有权、备份和无包管理边界。
标准库unittest可直接运行，不依赖项目测试框架。
"""
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "geek-setup.sh"


class RefreshTests(unittest.TestCase):
    """从脚本中加载函数定义后覆盖专属路径变量，不重设系统HOME。"""

    def setUp(self):
        """每个测试独占临时资源，失败后也由addCleanup释放。"""
        temporary = tempfile.TemporaryDirectory(prefix="geek-refresh-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.rc = self.root / "geekrc"
        text = SCRIPT.read_text()
        self.functions = self.root / "functions.sh"
        self.functions.write_text(text[:text.index('case "${1:-}" in')])
        self.original = text.split("<<'GEEKEOF'\n", 1)[1].split("\nGEEKEOF", 1)[0] + "\n"

    def invoke(self, injected=""):
        """仅调用refresh；其它有副作用命令若意外触发即失败并留痕。"""
        code = '''source "$1"
GEEKRC="$2"
BASHRC="$3/bashrc"
STATE_DIR="$3/state"
SHORTCUT="$3/geek"
FORBIDDEN_LOG="$3/forbidden"
apt-get() { echo apt-get >> "$FORBIDDEN_LOG"; return 99; }
sudo() { echo sudo >> "$FORBIDDEN_LOG"; return 99; }
install_tools() { echo install_tools >> "$FORBIDDEN_LOG"; return 99; }
wire_bashrc() { echo wire_bashrc >> "$FORBIDDEN_LOG"; return 99; }
'''
        return subprocess.run(["bash", "-c", code + injected + "\ncmd_refresh",
                               "test", str(self.functions), str(self.rc), str(self.root)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def test_refresh_preserves_backup_permissions_and_other_files(self):
        """旧内容精确备份、权限保持且不产生bashrc/快捷链接/工具清单。"""
        old = self.original + "# local old marker\n"
        self.rc.write_text(old)
        self.rc.chmod(0o640)
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        backups = list(self.root.glob("geekrc.bak.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), old)
        self.assertEqual(self.rc.stat().st_mode & 0o777, 0o640)
        self.assertIn("local R='\\[\\e[0m\\]'", self.rc.read_text())
        self.assertEqual(sorted(p.name for p in self.root.iterdir()),
                         sorted(["functions.sh", "geekrc", backups[0].name]))

    def test_unmanaged_missing_and_symlink_are_rejected(self):
        """缺失/用户自建/符号链接不能被refresh接管。"""
        self.assertNotEqual(self.invoke().returncode, 0)
        self.rc.write_text("# user config\n")
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(self.rc.read_text(), "# user config\n")
        self.rc.unlink()
        target = self.root / "target"
        target.write_text(self.original)
        self.rc.symlink_to(target)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertTrue(self.rc.is_symlink())
        self.assertEqual(target.read_text(), self.original)

    def test_failed_generation_keeps_original(self):
        """生成失败不会截断原配置，保留恢复备份并清除临时输出。"""
        self.rc.write_text(self.original)
        result = self.invoke('write_geekrc() { printf broken > "$1"; return 1; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.rc.read_text(), self.original)
        self.assertEqual(list(self.root.glob("geekrc.new.*")), [])
        self.assertEqual(len(list(self.root.glob("geekrc.bak.*"))), 1)


if __name__ == "__main__":
    unittest.main()
