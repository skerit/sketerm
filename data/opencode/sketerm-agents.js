// sketerm agents plugin for opencode: pushes the events of the sub-agents
// that sketerm's MCP server runs (done, needs_input, error, ...) into the
// session that last called one of its agent_* tools, as a new message, so
// the orchestrator needs no waiter.
//
// Install: symlink this file into opencode's plugin directory, e.g.
//   mkdir -p ~/.config/opencode/plugin && ln -s /usr/share/sketerm/opencode/sketerm-agents.js ~/.config/opencode/plugin/
//
// It finds the sketerm MCP server THIS opencode process started (the
// server's registry record names its parent pid) through
// `<sketerm> mcp agent-wait --server --follow --json --parent <pid>`, which
// shares the agents' one delivery state with every agent_* result and
// waiter: nothing it delivers is handed out twice. Without a sketerm server
// it does nothing.

import { spawn } from "node:child_process"
import { basename } from "node:path"

/** opencode's MCP tool id rule: `<server>_<tool>`, each part sanitized. */
const sanitize = (value) => value.replace(/[^a-zA-Z0-9_-]/g, "_")

const escapeAttr = (value) => value.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")

export const SketermAgents = async ({ client }, options = {}) => {
  /** @type {{prefix: string, binary: string}[] | null} */
  let servers = null
  let target = null
  let follower = null

  // The sketerm entries of opencode's MCP config: their tool prefix and
  // the binary opencode runs for them (options.binary overrides it).
  async function discover() {
    if (servers) return servers
    const found = []
    try {
      const res = await client.config.get()
      for (const [key, entry] of Object.entries(res?.data?.mcp ?? {})) {
        const command = Array.isArray(entry?.command) ? entry.command : []
        if (entry?.type !== "local" || entry.enabled === false || command.length === 0) continue
        if (!/^sketerm(-mcp)?$/.test(basename(command[0]))) continue
        found.push({ prefix: sanitize(key) + "_agent_", binary: options.binary ?? command[0] })
      }
    } catch {
      return []
    }
    servers = found
    return servers
  }

  function deliver(line) {
    let msg
    try {
      msg = JSON.parse(line)
    } catch {
      return
    }
    if (msg?.type !== "wake" || typeof msg.content !== "string" || !target) return
    const attrs = Object.entries(msg.meta ?? {})
      .filter(([k, v]) => /^[a-zA-Z_][a-zA-Z0-9_]*$/.test(k) && typeof v === "string")
      .map(([k, v]) => ` ${k}="${escapeAttr(v)}"`)
      .join("")
    const text = `<sketerm-agent-event${attrs}>\n${msg.content}\n</sketerm-agent-event>`
    client.session.promptAsync({ path: { id: target }, body: { parts: [{ type: "text", text }] } }).catch(() => {})
  }

  // One follower for the server; started again by the next agent_* call
  // once it ended (the server restarted, or was not up yet).
  function follow(binary) {
    if (follower) return
    let child
    try {
      child = spawn(binary, ["mcp", "agent-wait", "--server", "--follow", "--json", "--parent", String(process.pid)], {
        stdio: ["ignore", "pipe", "ignore"],
      })
    } catch {
      return
    }
    follower = child
    let buf = ""
    child.stdout.setEncoding("utf8")
    child.stdout.on("data", (chunk) => {
      buf += chunk
      let nl
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl)
        buf = buf.slice(nl + 1)
        deliver(line)
      }
    })
    const ended = () => {
      if (follower === child) follower = null
    }
    child.on("exit", ended)
    child.on("error", ended)
  }

  return {
    "tool.execute.before": async (input) => {
      const hit = (await discover()).find((s) => input.tool.startsWith(s.prefix))
      if (!hit) return
      target = input.sessionID
      follow(hit.binary)
    },
    dispose: async () => {
      follower?.kill()
      follower = null
    },
  }
}
