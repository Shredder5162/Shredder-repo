data "github_repository" "myRepo" {
  full_name = "${var.github_organization}/${var.github_repository}"
}

resource "github_actions_runner_group" "vmss" {
  name                       = "azure-vmss-runners"
  visibility                 = "all"
  selected_repository_ids    = [] #data.github_repository.myRepo.repo_id
  allows_public_repositories = false
}
