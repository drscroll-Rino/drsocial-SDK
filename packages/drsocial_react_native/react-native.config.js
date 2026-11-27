// Autolinking: the Android package class and the iOS pod.
module.exports = {
  dependency: {
    platforms: {
      android: { packageImportPath: 'import com.drsocial.reactnative.DrSocialPackage;', packageInstance: 'new DrSocialPackage()' },
      ios: {},
    },
  },
};
