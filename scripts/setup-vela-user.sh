#!/usr/bin/env bash
# Vela NAS user setup — run as root (sudo)
# Creates an isolated user for the Vela agent with its own home, crontab, and Claude CLI.

set -euo pipefail

# ── 1. Create user ──────────────────────────────────────────────
# No login password (cron-only, no interactive login needed).
# Add to docker group for container deployment.
sudo useradd -m -s /bin/bash -G docker vela
echo "✓ User 'vela' created"

# ── 2. Move agent directory ────────────────────────────────────
sudo mv /home/nosferath/agent /home/vela/agent
sudo chown -R vela:vela /home/vela/agent
# Symlink from old location so existing sessions don't break
sudo ln -s /home/vela/agent /home/nosferath/agent
echo "✓ Agent directory moved to /home/vela/agent"

# ── 3. Grant read access to patron's knowledge base and projects ─
# (Constitution: read-only access to Zettelkasten and projects)
sudo setfacl -R -m u:vela:rX /home/nosferath/Zettelkasten
sudo setfacl -R -m u:vela:rX /home/nosferath/projects
sudo setfacl -d -m u:vela:rX /home/nosferath/Zettelkasten
sudo setfacl -d -m u:vela:rX /home/nosferath/projects
echo "✓ Read-only ACLs set for Zettelkasten and projects"

# ── 4. Install Claude CLI for vela user ─────────────────────────
sudo -u vela bash -c 'curl -fsSL https://cli.claude.ai/install.sh | sh'
echo "✓ Claude CLI installed for vela"

# ── 5. Git config ──────────────────────────────────────────────
sudo -u vela git config --global user.name "Vela"
sudo -u vela git config --global user.email "agent@cyanez.cl"
echo "✓ Git configured"

# ── 6. Set up crontab ──────────────────────────────────────────
sudo -u vela bash -c '(crontab -l 2>/dev/null; echo "53 8 * * * /home/vela/agent/scripts/tick.sh") | crontab -'
echo "✓ Crontab entry added (daily at 08:53)"

echo ""
echo "── Manual steps remaining ──"
echo ""
echo "1. Authenticate Claude CLI as vela:"
echo "   sudo -u vela claude login"
echo "   (This will open a browser — log in with the Max subscription account)"
echo ""
echo "2. Verify everything works:"
echo "   sudo -u vela bash -c 'cd /home/vela/agent && claude --version'"
echo "   sudo -u vela bash -c 'cd /home/vela/agent && claude -p \"echo hello\"'"
echo ""
echo "3. Make tick script executable:"
echo "   chmod +x /home/vela/agent/scripts/tick.sh"
echo ""
echo "Done. Vela is ready to operate autonomously."
