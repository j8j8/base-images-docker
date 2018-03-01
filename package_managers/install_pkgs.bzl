#Copyright 2017 Google Inc. All rights reserved.

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Rule for installing apt packages from a tar file into a docker image."""

def _generate_install_commands(tar, installation_cleanup_commands):
  return """
tar -xvf {tar}
dpkg -i --force-depends ./*.deb
dpkg --configure -a
apt-get install -f
{installation_cleanup_commands}
# delete the files that vary build to build
rm -f /var/log/dpkg.log
rm -f /var/log/alternatives.log
rm -f /var/cache/ldconfig/aux-cache
rm -f /var/cache/apt/pkgcache.bin
touch /run/mount/utab""".format(tar=tar, installation_cleanup_commands=installation_cleanup_commands)

def _impl(ctx, image_tar=None, installables_tar=None, installation_cleanup_commands=""):
  """Implementation for the container_image rule.

  Args:
    ctx: The bazel rule context
    image_tar: File, overrides ctx.file.image_tar
    installables_tar: File, overrides ctx.file.installables_tar
    installation_cleanup_commands: str, overrides ctx.attr.installation_cleanup_commands
  """
  image_tar = image_tar or ctx.file.image_tar
  installables_tar = installables_tar or ctx.file.installables_tar
  installation_cleanup_commands = installation_cleanup_commands or ctx.attr.installation_cleanup_commands

  installables_tar_path = installables_tar.path
  # Generate the installer.sh script
  install_script = ctx.new_file("%s.install" % (ctx.label.name))
  ctx.template_action(
      template=ctx.file._installer_tpl,
      substitutions= {
          "%{install_commands}": _generate_install_commands(installables_tar_path, installation_cleanup_commands),
          "%{installables_tar}": installables_tar_path,
      },
      output = install_script,
      executable = True,
  )

  builder_image_name = "bazel/%s:%s" % (image_tar.owner.package,
                                        image_tar.owner.name.split(".tar")[0])
  unstripped_tar = ctx.actions.declare_file(ctx.outputs.install_pkgs_out.basename + ".unstripped")

  build_contents = """\
#!/bin/bash
set -ex
# Load utils
source {util_script}

docker load --input {base_image_tar}

cid=$(docker run -d -v $(pwd)/{installables_tar}:/tmp/{installables_tar} -v $(pwd)/{installer_script}:/tmp/installer.sh --privileged {base_image_name} /tmp/installer.sh)

docker attach $cid || true

reset_cmd {base_image_name} $cid {output_image_name}
docker save {output_image_name} > {output_file_name}
""".format(util_script=ctx.file._image_utils.path,
           base_image_tar=image_tar.path,
           base_image_name=builder_image_name,
           installables_tar=installables_tar_path,
           installer_script=install_script.path,
           output_file_name=unstripped_tar.path,
           output_image_name=ctx.attr.output_image_name
  )

  script=ctx.actions.declare_file(ctx.label.name + ".build")
  ctx.actions.write(
    output=script,
    content=build_contents,
  )
  ctx.actions.run(
    outputs=[unstripped_tar],
    inputs=[image_tar, install_script, installables_tar, ctx.file._image_utils],
    executable=script,
  )

  ctx.actions.run(
    outputs=[ctx.outputs.install_pkgs_out],
    inputs=[unstripped_tar],
    executable=ctx.executable._config_stripper,
    arguments=['--in_tar_path=%s' % unstripped_tar.path, '--out_tar_path=%s' % ctx.outputs.install_pkgs_out.path],
  )

  return struct ()

_attrs = {
    "image_tar": attr.label(
        default = Label("//ubuntu:ubuntu_16_0_4_vanilla.tar"),
        allow_files = True,
        single_file = True,
        mandatory = True,
    ),
    "installables_tar": attr.label(
        allow_files = True,
        single_file = True,
        mandatory = True,
    ),
    "installation_cleanup_commands": attr.string(
        default = "",
    ),
    "output_image_name": attr.string(
        mandatory = True,
    ),
    "_installer_tpl": attr.label(
        default = Label("//package_managers:installer.sh.tpl"),
        single_file = True,
        allow_files = True,
    ),
    "_config_stripper": attr.label(
        default = "//util:config_stripper",
        executable = True,
        cfg = "host",
    ),
    "_image_utils": attr.label(
        default = "//util:image_util.sh",
        allow_files = True,
        single_file = True,
    ),
}

_outputs = {
    "install_pkgs_out": "%{output_image_name}.tar",
}

install = struct(
    attrs = _attrs,
    outputs = _outputs,
    implementation = _impl,
)

install_pkgs = rule(
    attrs = _attrs,
    outputs = _outputs,
    implementation = _impl,
)
