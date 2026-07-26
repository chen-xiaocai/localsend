import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/widget/big_button.dart';
import 'package:localsend_app/widget/dialogs/custom_bottom_sheet.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

class AddFileDialog extends StatelessWidget {
  final List<FilePickerOption> options;
  final BuildContext parentContext;

  const AddFileDialog({required this.options, required this.parentContext});

  static Future<void> open({required BuildContext context, required List<FilePickerOption> options}) async {
    if (checkPlatformIsDesktop()) {
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(t.dialogs.addFile.title),
          content: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 300),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.dialogs.addFile.content),
                const SizedBox(height: 20),
                AddFileDialog(options: options, parentContext: context),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                context.pop();
              },
              child: Text(t.general.close),
            ),
          ],
        ),
      );
    } else {
      await context.pushBottomSheet(
        () => CustomBottomSheet(
          title: t.dialogs.addFile.title,
          description: t.dialogs.addFile.content,
          child: AddFileDialog(options: options, parentContext: context),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 15,
      runSpacing: 15,
      children: [
        ...options.map((option) {
          return BigButton(
            icon: option.icon,
            label: option.label,
            filled: true,
            onTap: () async {
              context.popUntilRoot();
              if (!parentContext.mounted) {
                return;
              }
              await parentContext.global.dispatchAsync(PickFileAction(option: option, context: parentContext));
            },
          );
        }),
      ],
    );
  }
}
