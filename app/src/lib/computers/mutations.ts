import { mutationOptions, type QueryClient } from "@tanstack/react-query";
import { client } from "@/lib/client";
import { type ActionPolicy, computerKeys } from "./queries";

/** Stopping frees the container; resetting also deletes the browser profile. */
export type ComputerAction = "stop" | "reset";

function invalidateComputers(queryClient: QueryClient) {
  return queryClient.invalidateQueries({ queryKey: computerKeys.all });
}

export function setComputerStateMutationOptions(queryClient: QueryClient) {
  return mutationOptions({
    mutationFn: async (variables: {
      botId: string;
      action: ComputerAction;
    }) => {
      await client(
        `/api/computers/${encodeURIComponent(variables.botId)}/computers/${variables.action}`,
        {
          method: "POST",
          fallback: `The computer could not be ${variables.action}.`,
        },
      );
    },
    onSuccess: () => invalidateComputers(queryClient),
  });
}

/**
 * Replace the whole policy.
 *
 * A PUT rather than a patch because the rules are ordered and evaluated as a set: sending a
 * difference would leave the server deciding where a new rule belongs, and where a deny sits
 * relative to an allow is most of what a policy means.
 */
export function saveActionPolicyMutationOptions(queryClient: QueryClient) {
  return mutationOptions({
    mutationFn: (next: ActionPolicy): Promise<ActionPolicy> =>
      client("/api/computers/policy", "policy", {
        method: "PUT",
        body: next,
        fallback: "The boundary could not be saved.",
      }),
    onSuccess: () => invalidateComputers(queryClient),
  });
}

/**
 * Forget the saved policy, falling back to what the deployment's configuration says.
 *
 * Needed because the saved policy wins over configuration at boot: an administrator who edits
 * `AGENT_COMPUTER_POLICY` would otherwise keep enforcing whatever was saved here last.
 */
export function resetActionPolicyMutationOptions(queryClient: QueryClient) {
  return mutationOptions({
    mutationFn: (): Promise<ActionPolicy> =>
      client("/api/computers/policy", "policy", {
        method: "DELETE",
        fallback: "The boundary could not be reset.",
      }),
    onSuccess: () => invalidateComputers(queryClient),
  });
}
