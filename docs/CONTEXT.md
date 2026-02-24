# CONTEXT
We are upgrading this local AI agent orchestrator repository. We are moving to a strict "Red-Green-Refactor" (RGR) pipeline. 

To manage different workflows, we need to build a dynamic architecture with a CLI Setup Wizard. The system has three modes:
1. **PM Pre-Flight:** Generate requirements from a vague idea.
2. **New Project Mode:** Standard RGR loop for new code.
3. **Existing Project Mode:** Backfill tests and refactor legacy code.

# TASKS TO EXECUTE
Please analyze the current Python orchestrator script, the `tmux` launch script, and the two prompt files (`NEW PROJECT PROMPTS.md` and `EXISTING PROJECT PROMPTS.md`). Implement the following architectural changes:

## 1. Create the Setup Wizard (`setup.py`)
Create a new interactive Python CLI script that acts as the entry point for the user. It should present a menu with 3 options:
- **Option 1: PM Planning (Pre-Flight)**
  - Prompts the user for a vague idea.
  - Calls `plan.py` (which you will build in step 2).
- **Option 2: Run New Project RGR Loop**
  - Reads `NEW PROJECT PROMPTS.md`.
  - Extracts the respective text for QA, Dev, and Refactor.
  - Writes/Overwrites the `CLAUDE.md` file in `mailboxes/qa/`, `mailboxes/dev/`, and `mailboxes/refactor/` with the exact text under their respective `FILE_TARGET` headers.
  - Launches the `tmux` 4-pane grid.
- **Option 3: Run Existing Project Backfill Loop**
  - Reads `EXISTING PROJECT PROMPTS.md`.
  - Extracts the respective text for QA, Dev, and Refactor.
  - Writes/Overwrites the `CLAUDE.md` file in `mailboxes/qa/`, `mailboxes/dev/`, and `mailboxes/refactor/`.
  - Launches the `tmux` 4-pane grid.

## 2. Create the Pre-Flight Script (`plan.py`)
Create a standalone Python script that acts as the PM Agent. 
- It generates a strict Product Requirements Document (PRD) from a user string and saves it to `mailboxes/qa/input.txt`.
- It runs standard terminal output (no tmux panes required) and exits.

## 3. Update Mailbox Initialization
Ensure the setup logic creates exactly three agent mailboxes on startup if they don't exist: 
- `mailboxes/qa/`
- `mailboxes/dev/`
- `mailboxes/refactor/`

## 4. Update the Tmux Launch Script (`launch.sh`)
Modify the `tmux` window creation logic to spawn exactly **4 panes** in a readable 2x2 grid (or 1 bottom + 3 top). 
- Pane 0: The Python Orchestrator (`ORCH`)
- Pane 1: QA Agent (`QA_RED`)
- Pane 2: Dev Agent (`DEV_GREEN`)
- Pane 3: Refactor Agent (`REFACTOR_BLUE`)
Ensure each agent pane is initialized inside its respective mailbox directory.

## 5. Update the Orchestrator State Machine (`orchestrator.py`)
Rewrite the Python main event loop to manage the 3-agent RGR flow.
- **Start State:** Watch `mailboxes/qa/input.txt`. Trigger the QA agent.
- **Step 1 (Red):** Wait for QA to output a test. Move payload to `mailboxes/dev/input.txt` and trigger Dev.
- **Step 2 (Green):** Wait for Dev to output working code. Move payload to `mailboxes/refactor/input.txt` and trigger Refactor.
- **Step 3 (Blue):** Wait for Refactor to output clean code. Log completion and idle.

Please review this plan, outline your exact steps to modify the files, and wait for my approval before making the changes.