[
  compile: [warnings_as_errors: true],
  credo: [strict: true],
  gettext: [enabled: false],
  doctor: [enabled: true],
  dependencies: [check_unused: true],
  custom: [
    [
      key: :release_smoke,
      name: "Release smoke",
      command: "bin/checks/release_smoke.sh",
      kind: :writer,
      skip_exit_code: 2
    ]
  ],
  profiles: [
    quick: [
      quick: true,
      stages: [:format, :compile, :credo, :doctor, :dependencies, :test]
    ]
  ]
]
