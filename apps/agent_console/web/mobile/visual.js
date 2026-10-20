/* 业务图标名 → Material Symbols Outlined 连字名；品牌 logo 仍用 favicon.svg，不走这里 */
const symbols={
  eye:'visibility',eyeOff:'visibility_off',back:'arrow_back',chevron:'chevron_right',search:'search',
  bell:'notifications',more:'more_horiz',plus:'add',message:'forum',groups:'groups',grid:'grid_view',
  user:'person',check:'check',close:'close',filter:'tune',smile:'sentiment_satisfied',spark:'auto_awesome',
  image:'image',file:'description',mic:'mic',send:'send',reply:'reply',forward:'forward',edit:'edit',
  trash:'delete',pin:'keep',phone:'call',video:'videocam',book:'menu_book',chart:'bar_chart',
  settings:'settings',link:'link',logout:'logout',clock:'schedule',copy:'content_copy',star:'star',
  share:'share',download:'download',play:'play_arrow',pause:'pause',camera:'photo_camera',shield:'shield',
  headset:'headset_mic',moon:'dark_mode',folder:'folder',bolt:'bolt',domain:'domain',lock:'lock',person:'person'
};
const icon=(name,cls='')=>`<span class="material-symbols-outlined i ${cls}" aria-hidden="true">${symbols[name]||symbols.grid}</span>`;
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

const emojiSets={常用:'😊 🙂 😀 😁 😂 🤣 😅 😆 😉 😍 🥰 😘 😋 😎 🤔 🥹 😇 🙃 😌 😴 😢 😭 😮 😳 😬 😑 😔 😞 😕 🙄 🤗 🫡 🥳 🤩 🤝 👍 👌 🙏 ❤️ 🎉 ✅ 👏 💪 ✨ 🌹 ☀️ ☕ 💯 🎁',笑脸:'😀 😃 😄 😁 😆 😅 😂 🤣 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 😚 😙 🥲 😋 😛 😜 🤪 😝 🤑 🤗 🤭 🫢 🫣 🤫 🤔 🫡 🤐 🤨 😐 😑 😶 🫥 😏 😒 🙄 😬 😮‍💨 🤥 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤢 🤧 🥵 🥶 🥴 😵 🤯 🤠 🥳 😎 🤓 🧐 😕 🫤 😟 🙁 ☹️ 😮 😯 😲 😳 🥺 🥹 😦 😧 😨 😰 😥 😢 😭 😱 😖 😣 😞 😓 😩 😫 🥱 😤 😡',手势:'👍 👎 👏 🙌 🫶 👐 🤲 🤝 🙏 ✍️ 💅 🤳 💪 👋 🤚 🖐️ ✋ 🖖 🫱 🫲 🫴 🫳 👌 🤌 🤏 ✌️ 🤞 🫰 🤟 🤘 🤙 👈 👉 👆 🖕 👇 ☝️ 🫵 ✊ 👊 🤛 🤜',心意:'❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 🩷 🩵 🩶 💔 ❤️‍🩹 ❤️‍🔥 💕 💞 💓 💗 💖 💘 💝 💟 ❣️ 💌 💋 🌹 🌷 🌸 🌺 🌻 🌼 🍀 💐 ✨ ⭐ 🌟 💫 ☀️ 🌈',动物:'🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🐔 🐧 🐦 🐤 🦆 🦉 🦋 🐝 🐢 🐳 🐬 🐟 🐙 🦀 🦄 🐴 🦖 🐘 🦒 🦔 🐿️ 🦥 🦦 🦭 🕊️',生活:'🍎 🍊 🍋 🍉 🍇 🍓 🍒 🍑 🥭 🍍 🥝 🥑 🍅 🥐 🍞 🍔 🍟 🍕 🍜 🍚 🍣 🍰 🎂 🍪 🍩 🍫 🍬 🍦 ☕ 🍵 🧋 🥤 🍹 🥂 🎁 🎈 🎉 🎊 🎀 🏆 🥇 🏅 ⚽ 🏀 🎮 🎧 🎵 📷 📱 💻 💡 📚 📝 📦 🛍️ 🛒',符号:'✅ ☑️ ✔️ ❌ ❎ ➕ ➖ ✖️ ➗ ❓ ❗ ❕ ❔ 💯 🔴 🟠 🟡 🟢 🔵 🟣 ⚪ ⚫ 🔔 🔕 📢 🔊 🔇 🔒 🔓 🔐 🔑 💬 💭 🗨️ ♻️ ⚠️ 🚫 ⛔ 🆗 🆒 🆕 🆓 🆙 🆘 ➡️ ⬅️ ⬆️ ⬇️ ↗️ ↘️ ↙️ ↖️ 🔄 🔁 🔜 🔝'};
const emojiNames={'😊':'开心 微笑 谢谢','👍':'好 收到 赞 同意','🙏':'谢谢 感谢 拜托','❤️':'爱心 感谢','✅':'完成 确认 成功','🎉':'庆祝 恭喜','👌':'好 没问题 收到','🤝':'合作 握手','🌹':'花 感谢','😢':'伤心 哭','😮':'惊讶','☕':'咖啡 休息','🫡':'收到 敬礼','💪':'加油','📦':'包裹 快递','🙂':'微笑 好的','😂':'笑 开心','🔔':'通知 铃铛'};
const stickerLabels=['收到啦','马上处理','感谢理解','请稍等','没问题','辛苦了','已完成','为您服务'];
function sticker(index){const label=stickerLabels[index%8],colors=['#dce8ff','#e2eee8','#f5e6de','#e9e5fa'];return `<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" class="sticker-art" viewBox="0 0 120 120" role="img" aria-label="${label}"><ellipse cx="60" cy="101" rx="31" ry="4" fill="#c2cede" opacity=".28"/><path d="M30 53 26 24 46 36Q60 31 74 36L94 24 90 54Q99 85 60 89 21 85 30 53" fill="${colors[index%4]}" stroke="#879bb8" stroke-width="2" stroke-linejoin="round"/><path d="m42 55 4 0m27 0 4 0" stroke="#5f7596" stroke-width="4" stroke-linecap="round"/><path d="m56 65 4 3 4-3M60 68v4m-6-1q6 6 12 0" fill="none" stroke="#5f7596" stroke-width="2" stroke-linecap="round"/><ellipse cx="39" cy="65" rx="6" ry="3" fill="#e1a49f" opacity=".5"/><ellipse cx="81" cy="65" rx="6" ry="3" fill="#e1a49f" opacity=".5"/><rect x="17" y="82" width="86" height="28" rx="10" fill="white" stroke="#e2e8f0"/><text x="60" y="101" text-anchor="middle" fill="#647eac" font-size="13" font-weight="600" font-family="system-ui, sans-serif">${label}</text></svg>`}
