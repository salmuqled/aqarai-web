import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en')
  ];

  /// Home welcome message
  ///
  /// In en, this message translates to:
  /// **'Welcome to Aqar Ai'**
  String get welcomeMessage;

  /// Search results title
  ///
  /// In en, this message translates to:
  /// **'Search Results'**
  String get searchResults;

  /// Helper text for search
  ///
  /// In en, this message translates to:
  /// **'Enter area to search'**
  String get enterAreaToSearch;

  /// Select area
  ///
  /// In en, this message translates to:
  /// **'Select Area'**
  String get selectArea;

  /// Alert: select governorate first
  ///
  /// In en, this message translates to:
  /// **'Please select governorate and area first'**
  String get selectGovernorateAndArea;

  /// Type of property
  ///
  /// In en, this message translates to:
  /// **'Property Type'**
  String get propertyType;

  /// Apartment
  ///
  /// In en, this message translates to:
  /// **'Apartment'**
  String get propertyType_apartment;

  /// House
  ///
  /// In en, this message translates to:
  /// **'House'**
  String get propertyType_house;

  /// Building
  ///
  /// In en, this message translates to:
  /// **'Building'**
  String get propertyType_building;

  /// Land
  ///
  /// In en, this message translates to:
  /// **'Land'**
  String get propertyType_land;

  /// Industrial land
  ///
  /// In en, this message translates to:
  /// **'Industrial Land'**
  String get propertyType_industrialLand;

  /// Shop
  ///
  /// In en, this message translates to:
  /// **'Shop'**
  String get propertyType_shop;

  /// Office
  ///
  /// In en, this message translates to:
  /// **'Office'**
  String get propertyType_office;

  /// Chalet
  ///
  /// In en, this message translates to:
  /// **'Chalet'**
  String get propertyType_chalet;

  /// For sale
  ///
  /// In en, this message translates to:
  /// **'For Sale'**
  String get forSale;

  /// For rent
  ///
  /// In en, this message translates to:
  /// **'For Rent'**
  String get forRent;

  /// Exchange
  ///
  /// In en, this message translates to:
  /// **'Exchange'**
  String get forExchange;

  /// Search button
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// Chalets section
  ///
  /// In en, this message translates to:
  /// **'Chalets'**
  String get chalets;

  /// Wanted section
  ///
  /// In en, this message translates to:
  /// **'Wanted'**
  String get wanted;

  /// Wanted list
  ///
  /// In en, this message translates to:
  /// **'Wanted Requests'**
  String get wantedList;

  String get myWantedRequests;

  /// Add wanted request
  ///
  /// In en, this message translates to:
  /// **'Post Request'**
  String get postWanted;

  /// Request description
  ///
  /// In en, this message translates to:
  /// **'Request Description'**
  String get propertyDescription;

  /// Login required
  ///
  /// In en, this message translates to:
  /// **'You must log in to continue'**
  String get errorMessagePlaceholder;

  /// Valuation page title
  ///
  /// In en, this message translates to:
  /// **'Property Valuation'**
  String get valuation;

  /// Valuation subtitle
  ///
  /// In en, this message translates to:
  /// **'Please fill out the following details to submit your request'**
  String get valuation_subtitle;

  /// Owner name
  ///
  /// In en, this message translates to:
  /// **'Owner Name'**
  String get valuation_ownerName;

  /// Phone number
  ///
  /// In en, this message translates to:
  /// **'Phone Number'**
  String get valuation_phone;

  /// Governorate
  ///
  /// In en, this message translates to:
  /// **'Governorate'**
  String get valuation_governorate;

  /// Area
  ///
  /// In en, this message translates to:
  /// **'Area'**
  String get valuation_area;

  /// Type
  ///
  /// In en, this message translates to:
  /// **'Property Type'**
  String get valuation_propertyType;

  /// Size
  ///
  /// In en, this message translates to:
  /// **'Property Size (m²)'**
  String get valuation_propertyArea;

  /// Build year
  ///
  /// In en, this message translates to:
  /// **'Build Year'**
  String get valuation_buildYear;

  /// Condition
  ///
  /// In en, this message translates to:
  /// **'Condition'**
  String get valuation_condition;

  /// New
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get valuation_condition_new;

  /// Very good
  ///
  /// In en, this message translates to:
  /// **'Very Good'**
  String get valuation_condition_veryGood;

  /// Good
  ///
  /// In en, this message translates to:
  /// **'Good'**
  String get valuation_condition_good;

  /// Needs work
  ///
  /// In en, this message translates to:
  /// **'Needs Renovation'**
  String get valuation_condition_needsWork;

  /// Purpose
  ///
  /// In en, this message translates to:
  /// **'Purpose'**
  String get valuation_purpose;

  /// Sale
  ///
  /// In en, this message translates to:
  /// **'For Sale'**
  String get valuation_purpose_sale;

  /// Rent
  ///
  /// In en, this message translates to:
  /// **'For Rent'**
  String get valuation_purpose_rent;

  /// Mortgage
  ///
  /// In en, this message translates to:
  /// **'Mortgage'**
  String get valuation_purpose_mortgage;

  /// Market evaluation
  ///
  /// In en, this message translates to:
  /// **'Market Evaluation'**
  String get valuation_purpose_market;

  /// Notes
  ///
  /// In en, this message translates to:
  /// **'Additional Notes'**
  String get valuation_notes;

  /// Submit button
  ///
  /// In en, this message translates to:
  /// **'Submit Valuation Request'**
  String get valuation_submit;

  /// Saved
  ///
  /// In en, this message translates to:
  /// **'Valuation request submitted successfully'**
  String get valuation_saved;

  /// Error
  ///
  /// In en, this message translates to:
  /// **'An error occurred while submitting the request'**
  String get valuation_error;

  /// Required field
  ///
  /// In en, this message translates to:
  /// **'This field is required'**
  String get valuation_required;

  /// Apartment
  ///
  /// In en, this message translates to:
  /// **'Apartment'**
  String get valuation_type_apartment;

  /// Villa
  ///
  /// In en, this message translates to:
  /// **'Villa'**
  String get valuation_type_villa;

  /// Land
  ///
  /// In en, this message translates to:
  /// **'Land'**
  String get valuation_type_land;

  /// Commercial
  ///
  /// In en, this message translates to:
  /// **'Commercial'**
  String get valuation_type_commercial;

  /// Add property button
  ///
  /// In en, this message translates to:
  /// **'Add Property'**
  String get addProperty;

  /// Admin follow up
  ///
  /// In en, this message translates to:
  /// **'Ads Review'**
  String get adminFollowup;

  /// Approve button
  ///
  /// In en, this message translates to:
  /// **'Approve'**
  String get approve;

  /// Reject button
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get reject;

  /// Price
  ///
  /// In en, this message translates to:
  /// **'Price'**
  String get propertyPrice;

  /// Size
  ///
  /// In en, this message translates to:
  /// **'Size (m²)'**
  String get propertySize;

  /// Choose image
  ///
  /// In en, this message translates to:
  /// **'Choose Property Image'**
  String get choosePropertyImage;

  /// Number of rooms
  ///
  /// In en, this message translates to:
  /// **'Rooms'**
  String get roomCount;

  /// Master rooms
  ///
  /// In en, this message translates to:
  /// **'Master Rooms'**
  String get masterRoomCount;

  /// Bathrooms
  ///
  /// In en, this message translates to:
  /// **'Bathrooms'**
  String get bathroomCount;

  /// Parking spots
  ///
  /// In en, this message translates to:
  /// **'Parking Spots'**
  String get parkingCount;

  /// Elevator
  ///
  /// In en, this message translates to:
  /// **'Elevator'**
  String get hasElevator;

  /// Central AC
  ///
  /// In en, this message translates to:
  /// **'Central AC'**
  String get hasCentralAC;

  /// Split AC
  ///
  /// In en, this message translates to:
  /// **'Split AC'**
  String get hasSplitAC;

  /// Maid room
  ///
  /// In en, this message translates to:
  /// **'Maid Room'**
  String get hasMaidRoom;

  /// Driver room
  ///
  /// In en, this message translates to:
  /// **'Driver Room'**
  String get hasDriverRoom;

  /// Laundry room
  ///
  /// In en, this message translates to:
  /// **'Laundry Room'**
  String get hasLaundryRoom;

  /// Garden
  ///
  /// In en, this message translates to:
  /// **'Garden'**
  String get hasGarden;

  /// Description
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get description;

  /// Publish button
  ///
  /// In en, this message translates to:
  /// **'Publish Property'**
  String get publishProperty;

  /// Publishing
  ///
  /// In en, this message translates to:
  /// **'Publishing...'**
  String get publishing;

  /// No items
  ///
  /// In en, this message translates to:
  /// **'No items found'**
  String get noWantedItems;

  /// Matches
  ///
  /// In en, this message translates to:
  /// **'Matches'**
  String get matches;

  /// Expired
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get expired;

  /// Area
  ///
  /// In en, this message translates to:
  /// **'Area'**
  String get areaLabel;

  /// Block
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get blockLabel;

  /// Matched date
  ///
  /// In en, this message translates to:
  /// **'Matched On'**
  String get matched;

  /// Budget
  ///
  /// In en, this message translates to:
  /// **'Budget'**
  String get budget;

  /// Price
  ///
  /// In en, this message translates to:
  /// **'Price'**
  String get price;

  /// Type
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get type;

  /// Login button
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get login;

  /// Post
  ///
  /// In en, this message translates to:
  /// **'Post'**
  String get post;

  /// Retry
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// Minimum price
  ///
  /// In en, this message translates to:
  /// **'Min Price'**
  String get minPrice;

  /// Maximum price
  ///
  /// In en, this message translates to:
  /// **'Max Price'**
  String get maxPrice;

  /// Saved
  ///
  /// In en, this message translates to:
  /// **'Saved successfully'**
  String get requestSaved;

  /// Error
  ///
  /// In en, this message translates to:
  /// **'An error occurred while saving request'**
  String get requestError;

  /// Properties in area
  ///
  /// In en, this message translates to:
  /// **'Properties in {area}'**
  String propertiesInArea(String area);

  /// Search results per area
  ///
  /// In en, this message translates to:
  /// **'Search results for {area}'**
  String searchResultsForArea(String area);

  /// No description provided for @myAds.
  ///
  /// In en, this message translates to:
  /// **'My Ads'**
  String get myAds;

  /// No description provided for @all.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get all;

  /// No description provided for @active.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get active;

  /// No description provided for @expiredAds.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get expiredAds;

  /// No description provided for @featuredAds.
  ///
  /// In en, this message translates to:
  /// **'Featured'**
  String get featuredAds;

  /// Featured wanted section title
  String get featuredWanted;

  /// No description provided for @addedOn.
  ///
  /// In en, this message translates to:
  /// **'Added On'**
  String get addedOn;

  /// No description provided for @expiresOn.
  ///
  /// In en, this message translates to:
  /// **'Expires On'**
  String get expiresOn;

  /// No description provided for @endsIn.
  ///
  /// In en, this message translates to:
  /// **'Ends In'**
  String get endsIn;

  /// No description provided for @days.
  ///
  /// In en, this message translates to:
  /// **'days'**
  String get days;

  /// No description provided for @featuredUntil.
  ///
  /// In en, this message translates to:
  /// **'Featured Until'**
  String get featuredUntil;

  /// No description provided for @makeFeatured.
  ///
  /// In en, this message translates to:
  /// **'Make Featured'**
  String get makeFeatured;

  /// No description provided for @extendFeature.
  ///
  /// In en, this message translates to:
  /// **'Extend Feature'**
  String get extendFeature;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @hardDeleteWarning.
  ///
  /// In en, this message translates to:
  /// **'This ad will be permanently deleted'**
  String get hardDeleteWarning;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// Logout
  ///
  /// In en, this message translates to:
  /// **'Logout'**
  String get logout;

  /// Logout confirmation
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to logout?'**
  String get logoutConfirm;

  /// Logout success
  ///
  /// In en, this message translates to:
  /// **'Logged out successfully'**
  String get logoutSuccess;

  /// Login title
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get loginTitle;

  /// Email
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get email;

  /// Password
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// Forgot password
  ///
  /// In en, this message translates to:
  /// **'Forgot password?'**
  String get forgotPassword;

  /// Google button
  ///
  /// In en, this message translates to:
  /// **'Continue with Google'**
  String get continueWithGoogle;

  /// Apple button
  ///
  /// In en, this message translates to:
  /// **'Continue with Apple'**
  String get continueWithApple;

  /// Create account
  ///
  /// In en, this message translates to:
  /// **'Create a new account'**
  String get createAccount;

  /// Full name
  ///
  /// In en, this message translates to:
  /// **'Full Name'**
  String get fullName;

  /// No description provided for @or.
  ///
  /// In en, this message translates to:
  /// **'OR'**
  String get or;

  /// No description provided for @noAccount.
  ///
  /// In en, this message translates to:
  /// **'Don\'t have an account?'**
  String get noAccount;

  /// Sign up with email button
  String get signUpWithEmail;

  /// Sign in with email link
  String get signInWithEmail;

  /// Already have account
  String get haveAccount;

  /// Password mismatch message
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get passwordsDoNotMatch;

  /// Confirm password
  ///
  /// In en, this message translates to:
  /// **'Confirm Password'**
  String get confirmPassword;

  /// Send reset link
  ///
  /// In en, this message translates to:
  /// **'Send reset link'**
  String get sendResetLink;

  /// Reset password description
  ///
  /// In en, this message translates to:
  /// **'Enter your email and we will send you a reset link'**
  String get resetPasswordDesc;

  /// Property details page title
  ///
  /// In en, this message translates to:
  /// **'Property Details'**
  String get propertyDetails;

  /// Owner info section
  ///
  /// In en, this message translates to:
  /// **'Owner Information'**
  String get ownerInfo;

  /// Visible only for admin
  ///
  /// In en, this message translates to:
  /// **'Owner Info (Admin Only)'**
  String get ownerOnlyAdmin;

  /// Type label
  ///
  /// In en, this message translates to:
  /// **'Property Type'**
  String get typeLabel;

  /// Service type label
  ///
  /// In en, this message translates to:
  /// **'Service Type'**
  String get serviceTypeLabel;

  /// Ad status
  ///
  /// In en, this message translates to:
  /// **'Ad Status'**
  String get statusLabel;

  /// Property features
  ///
  /// In en, this message translates to:
  /// **'Features'**
  String get features;

  /// Property description
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get descriptionLabel;

  /// No description
  ///
  /// In en, this message translates to:
  /// **'No description available'**
  String get noDescription;

  /// Call owner button
  ///
  /// In en, this message translates to:
  /// **'Call Owner'**
  String get callOwner;

  /// Added on date
  ///
  /// In en, this message translates to:
  /// **'Added On:'**
  String get addedOnDate;

  /// Owner name
  ///
  /// In en, this message translates to:
  /// **'Owner Name'**
  String get ownerNameLabel;

  /// Owner phone number
  ///
  /// In en, this message translates to:
  /// **'Owner Phone'**
  String get ownerPhoneLabel;

  /// Ad identifier
  ///
  /// In en, this message translates to:
  /// **'Ad ID'**
  String get adIdLabel;

  /// Service type in chalet search
  ///
  /// In en, this message translates to:
  /// **'Service Type'**
  String get serviceType;

  /// Service: sale
  ///
  /// In en, this message translates to:
  /// **'For Sale'**
  String get sale;

  /// Service: rent
  ///
  /// In en, this message translates to:
  /// **'For Rent'**
  String get rent;

  /// Service: exchange
  ///
  /// In en, this message translates to:
  /// **'Exchange'**
  String get exchange;

  String get imInterested;

  String get interestedDetails;

  String get adLabel;
  String get passwordResetSent;
  String get adFeaturedSevenDays;
  String get errorLabel;
  String get propertySentForReview;
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['ar', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {


  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar': return AppLocalizationsAr();
    case 'en': return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.'
  );
}
