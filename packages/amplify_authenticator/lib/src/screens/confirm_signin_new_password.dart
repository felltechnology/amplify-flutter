/*
 * Copyright 2021 Amazon.com, Inc. or its affiliates. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License").
 * You may not use this file except in compliance with the License.
 * A copy of the License is located at
 *
 *  http://aws.amazon.com/apache2.0
 *
 * or in the "license" file accompanying this file. This file is distributed
 * on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
 * express or implied. See the License for the specific language governing
 * permissions and limitations under the License.
 */

import 'package:amplify_authenticator/src/state/inherited_forms.dart';
import 'package:amplify_authenticator/src/state/inherited_strings.dart';
import 'package:amplify_authenticator/src/widgets/containers.dart';
import 'package:flutter/material.dart';

class ConfirmSignInNewPasswordScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final _confirmSignInNewPasswordForm =
        InheritedForms.of(context).confirmSignInNewPasswordForm;
    final _title = InheritedStrings.of(context)!
        .resolver
        .titles
        .confirmSigninNewPassword(context);
    return AuthenticatorContainer(
        title: _title, form: _confirmSignInNewPasswordForm);
  }
}
