cat > /tmp/install.sh << 'EOF'
#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}   CYBERVPN TELEGRAM BOT INSTALLER${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Cek root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Jalankan sebagai root! gunakan: sudo bash install.sh${NC}" 
   exit 1
fi

echo -e "${YELLOW}📝 Masukkan Token Bot Telegram:${NC}"
read -p "Token: " BOT_TOKEN

if [ -z "$BOT_TOKEN" ]; then
    echo -e "${RED}Token tidak boleh kosong!${NC}"
    exit 1
fi

echo -e "${YELLOW}📦 Updating system...${NC}"
apt update && apt upgrade -y

echo -e "${YELLOW}📦 Installing Node.js...${NC}"
apt install nodejs npm -y

echo -e "${YELLOW}📁 Creating bot directory...${NC}"
mkdir -p /opt/telegram-bot
cd /opt/telegram-bot

echo -e "${YELLOW}📦 Installing node modules...${NC}"
npm init -y
npm install node-telegram-bot-api express

echo -e "${YELLOW}🤖 Creating bot script...${NC}"
cat > bot.js << BOT_EOF
const TelegramBot = require('node-telegram-bot-api');
const { exec, spawn } = require('child_process');

const TOKEN = '${BOT_TOKEN}';
const bot = new TelegramBot(TOKEN, { polling: true });

const processes = new Map();

function isDangerousCommand(command) {
    const cmdLower = command.toLowerCase();
    if (cmdLower.includes('rm -rf') || cmdLower.includes('rm -rf /')) {
        return { blocked: true, reason: `⚠️ *DANGER!* Perintah \`rm -rf\` diblokir untuk melindungi data.\n\nGunakan \`rm -ri\` atau \`rm -r\` jika benar-benar perlu.` };
    }
    return { blocked: false };
}

function formatTime(seconds) {
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return mins > 0 ? `${mins}m ${secs}s` : `${secs}s`;
}

function getProgressBar(percent, width = 15) {
    const filled = Math.floor(percent * width / 100);
    const empty = width - filled;
    return '█'.repeat(filled) + '░'.repeat(empty);
}

async function executeCommand(chatId, command, msgId) {
    const check = isDangerousCommand(command);
    if (check.blocked) {
        bot.sendMessage(chatId, `🚫 *BLOCKED:*\n${check.reason}`, { parse_mode: 'Markdown' });
        return;
    }

    const startTime = Date.now();
    let completed = false;
    let lastOutputLength = 0;
    let noOutputCount = 0;
    let timeoutId;
    
    timeoutId = setTimeout(() => {
        if (!completed) {
            const proc = processes.get(chatId);
            if (proc) proc.kill('SIGTERM');
            bot.sendMessage(chatId, `⏰ *TIMEOUT* - Command dihentikan setelah 10 menit.\nCommand: \`${command}\``, { parse_mode: 'Markdown' });
            processes.delete(chatId);
            completed = true;
        }
    }, 600000);

    const statusMsg = await bot.sendMessage(chatId, 
        `⏳ *RUNNING:* \`${command.substring(0, 60)}${command.length > 60 ? '...' : ''}\``,
        { parse_mode: 'Markdown' }
    );

    let fullOutput = '';
    let intervalId;
    
    const process = spawn('bash', ['-c', command]);
    processes.set(chatId, process);

    intervalId = setInterval(async () => {
        if (completed) return;
        
        const elapsed = Math.floor((Date.now() - startTime) / 1000);
        
        const hasReplPrompt = fullOutput.includes('>>> ') || 
                              fullOutput.includes('> ') || 
                              fullOutput.includes('$ ') ||
                              fullOutput.includes('mysql> ') ||
                              fullOutput.includes('node> ') ||
                              fullOutput.includes('irb(main)') ||
                              fullOutput.includes('sqlite> ');
        
        if (hasReplPrompt && !completed) {
            completed = true;
            clearInterval(intervalId);
            clearTimeout(timeoutId);
            process.kill('SIGTERM');
            
            const totalTime = Math.floor((Date.now() - startTime) / 1000);
            let outputDisplay = fullOutput.length > 0 ? fullOutput.slice(-2500) : '(no output)';
            if (outputDisplay.length > 2000) outputDisplay = outputDisplay.slice(-2000) + '\n... (truncated)';
            
            const resultMsg = 
                `┌─────────────────────────────────────\n` +
                `│ 🖥️ *REPL/SHELL DETECTED*\n` +
                `├─────────────────────────────────────\n` +
                `│ 📤 *OUTPUT:*\n` +
                `│ \`\`\`\n${outputDisplay}\`\`\`\n` +
                `└─────────────────────────────────────\n` +
                `⏱️ *Total time:* ${formatTime(totalTime)}\n` +
                `💡 Program masuk ke mode interaktif. Gunakan \`cancel\` jika perlu.`;
            
            bot.editMessageText(resultMsg, {
                chat_id: chatId,
                message_id: statusMsg.message_id,
                parse_mode: 'Markdown'
            }).catch(() => {
                bot.sendMessage(chatId, resultMsg, { parse_mode: 'Markdown' });
            });
            
            processes.delete(chatId);
            return;
        }
        
        const currentLength = fullOutput.length;
        if (currentLength === lastOutputLength) {
            noOutputCount++;
        } else {
            noOutputCount = 0;
            lastOutputLength = currentLength;
        }
        
        let progress = 0;
        const progressMatch = fullOutput.match(/(\d+)%/);
        if (progressMatch) progress = parseInt(progressMatch[1]);
        
        let preview = fullOutput.slice(-300).split('\n').slice(-3).join('\n');
        if (preview.length === 0) preview = '⏳ Waiting for output...';
        else if (preview.length > 200) preview = preview.slice(-200) + '...';
        
        let progressDisplay = '';
        if (progress > 0) {
            progressDisplay = `${getProgressBar(progress)} ${progress}%`;
        } else {
            const spinner = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'][elapsed % 10];
            progressDisplay = `${spinner} Processing...`;
        }
        
        let warning = '';
        if (noOutputCount >= 15 && currentLength > 0) {
            warning = '\n⚠️ *No new output for 30 seconds*';
        }
        
        await bot.editMessageText(
            `⏳ *RUNNING:* \`${command.substring(0, 45)}${command.length > 45 ? '...' : ''}\`\n` +
            `┌─────────────────────────────────────\n` +
            `│ ${progressDisplay}\n` +
            `│ 📝 *Last output:*\n` +
            `│ \`${preview.replace(/`/g, "'")}\`\n` +
            `└─────────────────────────────────────\n` +
            `🕐 *Elapsed:* ${formatTime(elapsed)}${warning}`,
            {
                chat_id: chatId,
                message_id: statusMsg.message_id,
                parse_mode: 'Markdown'
            }
        ).catch(() => {});
        
        if (noOutputCount >= 30 && !completed) {
            process.kill('SIGTERM');
            bot.editMessageText(
                `🛑 *AUTO-CANCELLED* - No output for 60 seconds\nCommand: \`${command}\``,
                {
                    chat_id: chatId,
                    message_id: statusMsg.message_id,
                    parse_mode: 'Markdown'
                }
            ).catch(() => {});
            completed = true;
            clearInterval(intervalId);
            clearTimeout(timeoutId);
            processes.delete(chatId);
        }
    }, 2000);

    process.stdout.on('data', (data) => {
        fullOutput += data;
    });

    process.stderr.on('data', (data) => {
        fullOutput += data;
    });

    process.on('close', (code) => {
        if (completed) return;
        
        completed = true;
        clearInterval(intervalId);
        clearTimeout(timeoutId);
        
        const totalTime = Math.floor((Date.now() - startTime) / 1000);
        let outputDisplay = fullOutput.length > 0 ? fullOutput.slice(-2500) : '(no output)';
        if (outputDisplay.length > 2000) outputDisplay = outputDisplay.slice(-2000) + '\n... (truncated)';
        
        const statusIcon = code === 0 ? '✅' : '❌';
        const statusText = code === 0 ? 'SUCCESS' : `FAILED (code: ${code})`;
        
        const resultMsg = 
            `┌─────────────────────────────────────\n` +
            `│ ${statusIcon} *${statusText}*\n` +
            `├─────────────────────────────────────\n` +
            `│ 📤 *OUTPUT:*\n` +
            `│ \`\`\`\n${outputDisplay}\`\`\`\n` +
            `└─────────────────────────────────────\n` +
            `⏱️ *Total time:* ${formatTime(totalTime)}`;
        
        bot.editMessageText(resultMsg, {
            chat_id: chatId,
            message_id: statusMsg.message_id,
            parse_mode: 'Markdown'
        }).catch(() => {
            bot.sendMessage(chatId, resultMsg, { parse_mode: 'Markdown' });
        });
        
        processes.delete(chatId);
    });
}

bot.onText(/\/start/, async (msg) => {
    const help = 
        `🤖 *CYBERVPN TERMINAL BOT*\n` +
        `━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n` +
        `✅ *Cara pakai:* Kirim command seperti di terminal!\n\n` +
        `📦 *Contoh command:*\n` +
        `• \`apt update\`\n` +
        `• \`apt upgrade -y\`\n` +
        `• \`apt install nginx\`\n` +
        `• \`ls -la /mnt/drive\`\n` +
        `• \`docker ps\`\n` +
        `• \`python3 -v\`\n` +
        `• \`node -v\`\n` +
        `• \`top\`\n\n` +
        `📊 *Shortcut:*\n` +
        `• \`disk\` - Storage info\n` +
        `• \`mem\` - RAM & swap\n` +
        `• \`htop\` - Top processes\n` +
        `• \`status\` - System info\n` +
        `• \`cancel\` - Stop current task\n\n` +
        `⚠️ *Diblokir:* \`rm -rf\`\n` +
        `⏱️ *Timeout:* 10 menit\n` +
        `━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`;
    
    bot.sendMessage(msg.chat.id, help, { parse_mode: 'Markdown' });
});

bot.onText(/^disk$/, async (msg) => {
    exec("df -h / /mnt/drive 2>/dev/null | tail -n +2", (err, stdout) => {
        bot.sendMessage(msg.chat.id, `📀 *STORAGE USAGE*\n\`\`\`\n${stdout}\`\`\``, { parse_mode: 'Markdown' });
    });
});

bot.onText(/^mem$/, async (msg) => {
    exec("free -h", (err, stdout) => {
        bot.sendMessage(msg.chat.id, `🧠 *MEMORY INFO*\n\`\`\`\n${stdout}\`\`\``, { parse_mode: 'Markdown' });
    });
});

bot.onText(/^htop$/, async (msg) => {
    exec("ps aux --sort=-%mem | head -25", (err, stdout) => {
        bot.sendMessage(msg.chat.id, `📊 *TOP PROCESSES (by MEM)*\n\`\`\`\n${stdout}\`\`\``, { parse_mode: 'Markdown' });
    });
});

bot.onText(/^status$/, async (msg) => {
    exec("uptime && echo '' && free -h | grep Mem && df -h / | tail -1", (err, stdout) => {
        bot.sendMessage(msg.chat.id, `📊 *SYSTEM STATUS*\n\`\`\`\n${stdout}\`\`\``, { parse_mode: 'Markdown' });
    });
});

bot.onText(/^cancel$/, async (msg) => {
    const proc = processes.get(msg.chat.id);
    if (proc) {
        proc.kill('SIGINT');
        bot.sendMessage(msg.chat.id, '🛑 *Command cancelled by user*', { parse_mode: 'Markdown' });
        processes.delete(msg.chat.id);
    } else {
        bot.sendMessage(msg.chat.id, 'ℹ️ No active command', { parse_mode: 'Markdown' });
    }
});

bot.on('text', async (msg) => {
    const text = msg.text.trim();
    if (text === '/start') return;
    if (['disk', 'mem', 'htop', 'status', 'cancel'].includes(text)) return;
    if (text.startsWith('/')) return;
    
    executeCommand(msg.chat.id, text, msg.message_id);
});

console.log('🤖 CyberVPN Terminal Bot Started...');
BOT_EOF

echo -e "${YELLOW}🛠 Creating systemd service...${NC}"
cat > /etc/systemd/system/telegram-bot.service << 'EOF'
[Unit]
Description=Telegram Bot for Remote CLI
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/telegram-bot
ExecStart=/usr/bin/node /opt/telegram-bot/bot.js
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable telegram-bot
systemctl start telegram-bot

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ INSTALLATION COMPLETE!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}📱 Buka Telegram dan cari bot lo${NC}"
echo -e "${YELLOW}💬 Kirim /start untuk mulai${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

systemctl status telegram-bot --no-pager
EOF

chmod +x /tmp/install.sh
/tmp/install.sh
