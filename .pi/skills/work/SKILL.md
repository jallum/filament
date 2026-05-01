---
name: work
description: Execute a continuous, TDD-driven workflow using the `bw` tool to process tickets within an epic. Use this when you have an epic ID and need to work through its unblocked tickets one by one.
---

# Work Workflow

This skill implements a rigorous, ticket-by-ticket workflow using the `bw` issue tracker, following TDD principles and strict quality standards.

## The Workflow

When invoked with an `<epic_id>`, follow these steps:

1.  **Start the Epic**: Begin by marking the epic as in-progress:

    ```bash
    bw start <epic_id>
    ```

2.  **Identify Work**: Find the first unblocked ticket in the epic:

    ```bash
    bw ready <epic_id>
    ```

3.  **Start Ticket**: Start working on the identified ticket:

    ```bash
    bw start <ticket_id>
    ```

    **Crucial**: Read the output of this command carefully. It contains all the instructions and requirements for the task.

4.  **Implement (TDD)**:
    - Write a failing test that covers the requirement.
    - Write the minimal code to make the test pass.
    - **One commit per ticket**: Once the ticket is complete, commit your changes with a descriptive message related to the ticket.

5.  **Verify Quality**: Before committing and closing, you **must** ensure:
    - Deviations or deferrals require approval.
    - Compiles without warnings.
    - All tests pass.
    - Code formatting is correct (e.g., `prettier`, `black`, etc.).
    - Code hygiene tools/linters pass.
    - Test output is clean (no noise, warnings or extra logs).

6.  **Close Ticket**: Close the ticket:

    ```bash
    bw close <ticket_id>
    ```

    Observe the output to see which other tickets might have been unblocked.

7.  **Repeat**: Check for more ready tickets using `bw ready <epic_id>`. If there are more unblocked tickets, repeat from step 3. Continue until no more ready tickets are found.
