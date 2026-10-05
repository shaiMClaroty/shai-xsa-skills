# shai-xsa-skills

Cursor agent skills for xSA lab work.

## Skills

| Skill | What it does |
|-------|----------------|
| [create-proxy-server](create-proxy-server/SKILL.md) | Install a lab Squid HTTP forward proxy on an SRA host |

## Install a skill

Copy the skill folder into Cursor's personal skills directory:

```bash
mkdir -p ~/.cursor/skills
cp -R create-proxy-server ~/.cursor/skills/create-proxy-server
```

Invoke it in Cursor as `/create-proxy-server`.
