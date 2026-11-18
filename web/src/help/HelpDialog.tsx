import { For } from "solid-js";
import { MOD } from "../app/platform";
import { Dialog } from "../ui/Dialog";
import "./help.css";

const COMPOSING: readonly [string, string][] = [
  ["空格", "上屏第一个候选"],
  ["1 – 9", "上屏对应候选"],
  ["; ", "上屏第二个候选"],
  ["− =  ← →", "翻页"],
  ["⏎", "上屏所输入的编码"],
  ["⌫", "删除一个编码"],
  ["Esc", "取消输入"],
];

const PAGE: readonly [string, string][] = [
  ["Shift", "切换中 / 英"],
  [`${MOD}⏎`, "复制全部内容到剪贴板"],
  [`${MOD}⌫`, "清空内容（可撤销）"],
];

function Keys(props: { rows: readonly [string, string][] }) {
  return (
    <dl class="keys">
      <For each={props.rows}>
        {([keys, what]) => (
          <div class="keys-row">
            <dt>
              <kbd>{keys}</kbd>
            </dt>
            <dd>{what}</dd>
          </div>
        )}
      </For>
    </dl>
  );
}

export default function HelpDialog(props: { open: boolean; onClose: () => void }) {
  return (
    <Dialog open={props.open} title="帮助与快捷键" size="m" onClose={props.onClose}>
      <div class="help">
        <p class="help-lead">
          这是键道输入法的网页版：无需安装，打开就能用键道打字，写好后复制到别处粘贴。安装为应用后离线也能使用。
        </p>

        <h3 class="help-heading">输入时</h3>
        <Keys rows={COMPOSING} />

        <h3 class="help-heading">随时</h3>
        <Keys rows={PAGE} />

        <h3 class="help-heading">在手机和平板上</h3>
        <p>
          用系统自带的英文键盘输入编码，候选显示在键盘上方，轻点即可上屏；数字和符号直接输入。中/英切换在候选栏左侧。若要更完整的体验，可以安装 iOS 或
          Android 版键道。
        </p>

        <h3 class="help-heading">各平台客户端</h3>
        <p>
          键道还有 macOS、Windows、Linux、iOS 和 Android 版，与网页版使用同一个引擎（libjd）和同样格式的用户自造词文件。
          <a href="https://github.com/hronro/ime-jd/releases" target="_blank" rel="noopener">
            下载各平台版本
          </a>
        </p>

        <p class="help-version">版本 {__JD_VERSION__}</p>
      </div>
    </Dialog>
  );
}
