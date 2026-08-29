package main

workflow_trigger := object.get(input, "on", object.get(input, "true", null))

local_action_paths contains action_path if {
  some job_name
  job := input.jobs[job_name]
  some step in object.get(job, "steps", [])
  uses := object.get(step, "uses", "")
  startswith(uses, "./.github/actions/")
  action_path := trim_prefix(uses, "./")
}

local_reusable_workflow_paths contains workflow_path if {
  some job_name
  job := input.jobs[job_name]
  uses := object.get(job, "uses", "")
  startswith(uses, "./.github/workflows/")
  workflow_path := trim_prefix(uses, "./")
}

workflow_name_parts(name) := parts if {
  regex.match(`^[^/]+ / [^/]+$`, name)
  parts := split(name, " / ")
}

workflow_file_segment(part) := lower(replace(part, " ", "-"))

default workflow_file_name := ""

workflow_file_name := data.conftest.file.name if {
  data.conftest.file.name
}

deny contains msg if {
  name := object.get(input, "name", "")
  name != ""
  not workflow_name_parts(name)
  msg := "workflow name must follow {subsystem} / {task name}"
}

deny contains msg if {
  name := object.get(input, "name", "")
  parts := workflow_name_parts(name)
  expected := sprintf("%s--%s.yaml", [
    workflow_file_segment(parts[0]),
    workflow_file_segment(parts[1]),
  ])
  workflow_file_name != ""
  workflow_file_name != expected
  msg := sprintf("workflow file name must be .github/workflows/%s for name %q", [expected, name])
}

deny contains msg if {
  not object.get(input, "name", "")
  msg := "workflow must define a non-empty top-level name"
}

deny contains msg if {
  not workflow_trigger
  msg := "workflow must define a top-level on trigger"
}

deny contains msg if {
  not input.permissions
  msg := "workflow should define top-level permissions"
}

deny contains msg if {
  not input.jobs
  msg := "workflow must define at least one job"
}

deny contains msg if {
  some job_name
  job := input.jobs[job_name]
  not job["runs-on"]
  not job.uses
  msg := sprintf("job %q must define runs-on unless it uses a reusable workflow", [job_name])
}

deny contains msg if {
  some job_name
  job := input.jobs[job_name]
  not job.uses
  count(object.get(job, "steps", [])) == 0
  msg := sprintf("job %q must define at least one step unless it uses a reusable workflow", [job_name])
}

deny contains msg if {
  push := object.get(workflow_trigger, "push", null)
  pull_request := object.get(workflow_trigger, "pull_request", null)
  push != null
  pull_request != null
  not object.get(push, "branches", null)
  msg := "workflow with both push and pull_request triggers must define push.branches"
}

deny contains msg if {
  push := object.get(workflow_trigger, "push", null)
  pull_request := object.get(workflow_trigger, "pull_request", null)
  push != null
  pull_request != null
  not object.get(push, "paths", null)
  msg := "workflow with both push and pull_request triggers must define push.paths"
}

deny contains msg if {
  push := object.get(workflow_trigger, "push", null)
  pull_request := object.get(workflow_trigger, "pull_request", null)
  push != null
  pull_request != null
  not object.get(pull_request, "paths", null)
  msg := "workflow with both push and pull_request triggers must define pull_request.paths"
}

deny contains msg if {
  push := object.get(workflow_trigger, "push", null)
  pull_request := object.get(workflow_trigger, "pull_request", null)
  push != null
  pull_request != null
  push_paths := object.get(push, "paths", null)
  pull_request_paths := object.get(pull_request, "paths", null)
  push_paths != null
  pull_request_paths != null
  push_paths != pull_request_paths
  msg := "workflow push.paths and pull_request.paths must match"
}

deny contains msg if {
  some event_name, event in workflow_trigger
  paths := object.get(event, "paths", null)
  paths != null
  some action_path in local_action_paths
  required_path := sprintf("%s/action.yaml", [action_path])
  not required_path in paths
  msg := sprintf("add %q to on.%s.paths because this workflow uses local action %q", [
    required_path,
    event_name,
    sprintf("./%s", [action_path]),
  ])
}

deny contains msg if {
  some event_name, event in workflow_trigger
  paths := object.get(event, "paths", null)
  paths != null
  some workflow_path in local_reusable_workflow_paths
  not workflow_path in paths
  msg := sprintf("add %q to on.%s.paths because this workflow uses local reusable workflow %q", [
    workflow_path,
    event_name,
    sprintf("./%s", [workflow_path]),
  ])
}

deny contains msg if {
  count(local_action_paths) > 0
  some event_name, event in workflow_trigger
  paths := object.get(event, "paths", null)
  paths != null
  some path in paths
  normalized_path := trim_prefix(path, "!")
  startswith(normalized_path, ".github/actions/")
  contains(normalized_path, "*")
  msg := sprintf("replace wildcard path %q in on.%s.paths with each exact local action.yaml path; wildcard custom-action trigger paths are not allowed", [
    path,
    event_name,
  ])
}

deny contains msg if {
  some job_name
  job := input.jobs[job_name]
  some step_index, step in object.get(job, "steps", [])
  script := object.get(step, "run", "")
  regex.match(`(?m)^[\t ]*(if|for|while|until|case|select|foreach|switch)([\t (]|$)`, script)
  step_name := object.get(step, "name", sprintf("#%d", [step_index + 1]))
  msg := sprintf("move shell control flow from step %q in job %q into a tested repository script so branch and loop behavior is covered by tests", [
    step_name,
    job_name,
  ])
}
